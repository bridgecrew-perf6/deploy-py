#!/usr/bin/env python3

import subprocess
import shutil
import os
import tempfile
import sys
from time import time
from pprint import pformat
from functools import partial
from shlex import quote
from multiprocessing import Manager, Pool
from collections import namedtuple
from collections.abc import Sequence


def run(*args, **kwargs):
    options = {
        "check": True,
        "stdout": subprocess.PIPE,
        "stderr": subprocess.STDOUT,
        "universal_newlines": True,
    }
    options.update(kwargs)
    return subprocess.run(
        *args,
        **options,
    )


Task = namedtuple("Task", ["targets", "directory", "function"])
Result = namedtuple("Result", ["target", "value"])


class Skip(Exception):
    def __init__(self, reason=""):
        self.target = None
        self.reason = reason


class Error(Exception):
    def __init__(self, target, source):
        self.target = target
        self.source = source

    def __str__(self):
        return str(self.source)


class Target:
    ssh_path = None
    rsync_path = None

    def __init__(self, facts, name, ssh_options=None, rsync_options=None):
        self.name = name
        self.facts = facts
        self.ssh_options = ssh_options or []
        self.rsync_options = rsync_options or []

        if self.ssh_path is None:
            self.ssh_path = shutil.which("ssh")
            if self.ssh_path is None:
                raise RuntimeError("Could not find ssh executable")
        if self.rsync_path is None:
            self.rsync_path = shutil.which("rsync")
            if self.rsync_path is None:
                raise RuntimeError("Could not find rsync executable")

        self.cwd = "."

    def cd(self, directory):
        if directory is not None:
            self.cwd = os.path.join(self.cwd, directory)

    def run(self, command, directory="."):
        directory = os.path.normpath(os.path.join(self.cwd, directory))
        if not isinstance(command, str) and isinstance(command, Sequence):
            command = " ".join([quote(str(x)) for x in command])
        try:
            return run(
                [
                    self.ssh_path,
                    *self.ssh_options,
                    self.name,
                    "/bin/bash",
                ],
                input=f"set -euo pipefail\ncd {quote(directory)}\n{command}",
            )
        except subprocess.CalledProcessError as e:
            e.cmd = command
            raise e

    def copy(self, sources, destination=".", source_base=".", recursive=True):
        opts = []
        if recursive:
            opts += ["--recursive"]
        destination = os.path.normpath(os.path.join(self.cwd, destination))
        with tempfile.NamedTemporaryFile() as tmp:
            for source in sources:
                tmp.write(f"{source}\n".encode())
            tmp.flush()
            run(
                [
                    self.rsync_path,
                    *opts,
                    "--archive",
                    "--protect-args",
                    "--files-from",
                    tmp.name,
                    source_base,
                    f"{self.name}:{destination}",
                ],
            )


class Deployment:
    def __init__(self, targets):
        self.targets_cfg = targets
        self.tasks = []
        self.targets = None

    def task(self, targets=None, directory=None):
        def wrapper(function):
            self.tasks.append(Task(targets, directory, function))
            return function

        return wrapper

    @staticmethod
    def secure_task(task, target):
        try:
            return Result(target, task(target))
        except Skip as e:
            e.target = target
            return e
        except Exception as e:
            raise Error(target, e) from e

    def run_task(self, task, pool):
        targets = [
            i for i in self.targets if task.targets is None or i.name in task.targets
        ]
        for target in targets:
            target.cd(task.directory)
        target_names = " ".join([i.name for i in targets])
        print(f"{task.function.__name__}: {target_names}", flush=True)
        results = pool.imap_unordered(
            partial(self.secure_task, task.function),
            targets,
        )
        for i in range(len(targets)):
            try:
                r = next(results)
                if isinstance(r, Skip):
                    print(
                        f"  SKIP {r.target.name}"
                        + (": " + r.reason if r.reason else ""),
                        flush=True,
                    )
                elif r.value is None:
                    print(f"  DONE {r.target.name}", flush=True)
                else:
                    print(f"  DONE {r.target.name}:", flush=True)
                    if isinstance(r.value, str):
                        lines = r.value.rstrip().split("\n")
                    else:
                        lines = pformat(r.value).split("\n")
                    for line in lines:
                        print(f"    {line}", flush=True)
            except StopIteration:
                break
            except Error as e:
                print(f"{e.__cause__}\nTarget: {e.target.name}")
                if isinstance(e.source, subprocess.CalledProcessError):
                    print(f"Command: {e.source.cmd}\nOutput:")
                    for line in e.source.stdout.rstrip().split("\n"):
                        print(f"  {line}")
                sys.exit(1)

    def run(self):
        with Manager() as manager:
            self.targets = []
            for name, target in self.targets_cfg.items():
                self.targets.append(Target(manager.dict(), name, **target))
            with Pool(len(self.targets_cfg)) as pool:
                for task in self.tasks:
                    self.run_task(task, pool)


class SymlinkedRelease:
    git_path = None

    def __init__(
        self,
        current_path,
        shared_dir=None,
        linked_paths=None,
        keep=3,
        releases_dir=None,
        timestamp=None,
    ):
        self.timestamp = str(timestamp or int(time()))
        self.current_path = current_path
        self.shared_dir = shared_dir
        self.linked_paths = linked_paths or {}
        self.releases_dir = releases_dir or os.path.join(
            os.path.dirname(self.current_path),
            "releases",
        )
        self.keep = keep
        self.copy_paths = []
        self.revision = None
        if os.path.exists(".git"):
            self.get_git_metadata()
        self.new_release = os.path.join(self.releases_dir, self.timestamp)

    def detect_releases(self, target):
        old_release = None
        try:
            old_release = target.run(
                ["realpath", "-e", self.current_path]
            ).stdout.rstrip()
        except subprocess.CalledProcessError:
            pass
        target.facts["old_release"] = old_release
        releases = []
        try:
            releases = sorted(
                target.run(["ls", "-1", self.releases_dir]).stdout.split("\n"),
                reverse=True,
            )
            releases = [
                os.path.join(self.releases_dir, i) for i in releases
                if len(i) > 0 and i is not None
            ]
        except subprocess.CalledProcessError:
            pass
        target.facts["releases"] = releases

    def get_git_metadata(self):
        if self.git_path is None:
            self.git_path = shutil.which("git")
        if self.git_path is not None:
            try:
                self.copy_paths = (
                    run(
                        [
                            self.git_path,
                            "ls-files",
                            "--cached",
                            "--others",
                            "--exclude-standard",
                        ],
                    )
                    .stdout.rstrip()
                    .split("\n")
                )
                self.revision = run(
                    [
                        self.git_path,
                        "rev-parse",
                        "HEAD",
                    ]
                ).stdout.rstrip()
            except subprocess.CalledProcessError as e:
                print("Failed to discover files versioned in Git", file=sys.stderr)
                print(e.stdout, file=sys.stderr)
                raise e

    def copy(self, target, extra_paths=None, source="."):
        extra_paths = extra_paths or []
        target.run(["mkdir", "-p", self.new_release])
        target.copy(self.copy_paths + extra_paths, self.new_release, source_base=source)

    def link(self, target):
        target.run(["ln", "-Tsf", self.new_release, self.current_path])

    def link_shared(self, target):
        for dest, src in self.linked_paths.items():
            dest = os.path.join(self.new_release, dest)
            src = os.path.join(self.shared_dir, src)
            target.run(["rm", "-rf", dest])
            target.run(["ln", "-s", src, dest])

    def remove_old(self, target):
        old = target.facts["releases"][self.keep :]
        for release in old:
            target.run(["rm", "-rf", release])
        return old

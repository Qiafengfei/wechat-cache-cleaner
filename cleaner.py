"""Preview and clean selected Windows WeChat cache files."""

import argparse
import csv
import os
import stat
import subprocess
import sys
from pathlib import Path


WEB_CACHES = (
    "Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache",
)
WECHAT_PROCESSES = {
    "wechat.exe", "weixin.exe", "wechatappex.exe", "weixinappex.exe",
    "wechatplayer.exe", "weixinplayer.exe", "weixinupdate.exe", "xwechat.exe",
}


def ordinary_stat(path):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return None
    if stat.S_ISLNK(info.st_mode) or (
        getattr(info, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT
    ):
        return None
    return info


def ordinary_directory(path):
    info = ordinary_stat(path)
    return info is not None and stat.S_ISDIR(info.st_mode)


def safe_directory(path):
    return all(ordinary_directory(part) for part in (*reversed(path.parents), path))


def child_directories(path):
    if safe_directory(path):
        yield from (child for child in path.iterdir() if ordinary_directory(child))


def cache_targets(root, packages, plugins):
    radium = root / "radium"
    yield "Logs", root / "log"
    for profile in child_directories(radium / "web" / "profiles"):
        for name in WEB_CACHES:
            yield "Web cache", profile / name
    for user in child_directories(radium / "users"):
        applet = user / "applet"
        for name in ("codecache", "icon"):
            yield "Mini program cache", applet / name
        if packages:
            yield "Mini program packages", applet / "packages"
    if plugins:
        yield "Plugin files", root / "XPlugin" / "Plugins"


def files_below(directory):
    if not safe_directory(directory):
        return
    for child in directory.iterdir():
        info = ordinary_stat(child)
        if info is None:
            continue
        if stat.S_ISDIR(info.st_mode):
            yield from files_below(child)
        elif stat.S_ISREG(info.st_mode) and info.st_nlink == 1:
            yield child, info


def wechat_running():
    tasklist = Path(os.environ["SystemRoot"]) / "System32" / "tasklist.exe"
    result = subprocess.run(
        [str(tasklist), "/FO", "CSV", "/NH"],
        capture_output=True, text=True, errors="replace", check=True, timeout=20,
    )
    rows = list(csv.reader(result.stdout.splitlines()))
    if not any(len(row) == 5 and row[1].isdigit() for row in rows):
        raise RuntimeError("Unable to read the Windows process list.")
    return any(row and row[0].lower() in WECHAT_PROCESSES for row in rows)


def remove_file(path, original):
    if not safe_directory(path.parent):
        return False
    current = ordinary_stat(path)
    if current is None or current.st_nlink != 1 or not stat.S_ISREG(current.st_mode):
        return False
    if not os.path.samestat(original, current) or (
        original.st_size, original.st_mtime_ns
    ) != (current.st_size, current.st_mtime_ns):
        return False
    path.unlink()
    return True


def main(argv=None, root=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="permanently remove selected files")
    parser.add_argument("--packages", action="store_true", help="include mini program packages")
    parser.add_argument("--plugins", action="store_true", help="include installed plugin files")
    args = parser.parse_args(argv)

    try:
        if root is None:
            root = Path(os.environ["APPDATA"]) / "Tencent" / "xwechat"
        root = root.absolute()
        if not safe_directory(root):
            raise RuntimeError("WeChat directory is missing or uses a link.")
        if args.apply and wechat_running():
            raise RuntimeError("Exit WeChat from the system tray before applying cleanup.")

        groups = {}
        for label, directory in cache_targets(root, args.packages, args.plugins):
            group = groups.setdefault(label, [])
            group.extend(
                (path, info)
                for path, info in files_below(directory)
                if label != "Logs" or path.suffix.lower() == ".xlog"
            )

        print("Cleanup selection" if args.apply else "Preview only")
        total_count = total_size = 0
        for label, group in groups.items():
            size = sum(info.st_size for _, info in group)
            total_count += len(group)
            total_size += size
            print(f"{label:24} {len(group):5} files  {size / 2**20:8.2f} MiB")
        print(f"{'Total':24} {total_count:5} files  {total_size / 2**20:8.2f} MiB")
        if not args.apply:
            return 0
        if wechat_running():
            raise RuntimeError("WeChat started during the scan. Exit it before applying cleanup.")

        removed = removed_size = 0
        for group in groups.values():
            for path, info in group:
                try:
                    if remove_file(path, info):
                        removed += 1
                        removed_size += info.st_size
                except OSError as error:
                    print(f"Could not remove {path.relative_to(root)}: {error.strerror}", file=sys.stderr)
        skipped = total_count - removed
        print(f"Removed {removed} files ({removed_size / 2**20:.2f} MiB). Skipped {skipped}.")
        return int(skipped != 0)
    except (KeyError, OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Cleanup stopped: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

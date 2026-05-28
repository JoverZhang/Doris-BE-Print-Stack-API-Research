#!/usr/bin/env python3
import argparse
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from typing import Dict, Iterable, List, Optional, Tuple


MAP_RE = re.compile(r"^([0-9a-fA-F]+)-([0-9a-fA-F]+)\s+(\S+)\s+([0-9a-fA-F]+)\s+\S+\s+\S+(?:\s+(.*))?$")
THREAD_RE = re.compile(r"^tid:\s+(\d+),\s+tname:\s+([^,]+),\s+lbt:\s+(.*)$")
ADDR_RE = re.compile(r"0x[0-9a-fA-F]+")


@dataclass(frozen=True)
class Mapping:
    start: int
    end: int
    perms: str
    offset: int
    path: str
    host_path: str


@dataclass
class ThreadStack:
    tid: str
    name: str
    addrs: List[int]


@dataclass
class Frame:
    raw_addr: int
    object_path: Optional[str]
    object_addr: Optional[int]
    object_label: str
    note: str


def parse_display_prefix(value: str) -> Tuple[str, str]:
    if "=" not in value:
        raise argparse.ArgumentTypeError("display prefix must be OLD=NEW")
    old, new = value.split("=", 1)
    if not old:
        raise argparse.ArgumentTypeError("display prefix OLD side must not be empty")
    return old.rstrip("/"), new.rstrip("/")


def display_path(path: str, prefixes: Iterable[Tuple[str, str]]) -> str:
    if not path:
        return path
    normalized = path
    for old, new in prefixes:
        if normalized == old:
            return new
        if normalized.startswith(old + "/"):
            return new + normalized[len(old):]
    return normalized


def display_text(text: str, prefixes: Iterable[Tuple[str, str]]) -> str:
    normalized = text
    for old, new in prefixes:
        normalized = normalized.replace(old, new)
    return normalized


def host_path_for(path: str, repo_root: Optional[str]) -> str:
    if not path or path.startswith("["):
        return path
    if repo_root and (path == "/work" or path.startswith("/work/")):
        return repo_root.rstrip("/") + path[len("/work"):]
    return path


def parse_stack_file(path: str, repo_root: Optional[str]) -> Tuple[List[Mapping], List[ThreadStack]]:
    mappings: List[Mapping] = []
    threads: List[ThreadStack] = []
    with open(path, "r", encoding="utf-8", errors="replace") as stack:
        for raw_line in stack:
            line = raw_line.rstrip("\n")
            thread_match = THREAD_RE.match(line)
            if thread_match:
                threads.append(ThreadStack(
                    tid=thread_match.group(1),
                    name=thread_match.group(2),
                    addrs=[int(addr, 16) for addr in ADDR_RE.findall(thread_match.group(3))],
                ))
                continue

            map_match = MAP_RE.match(line)
            if not map_match:
                continue
            perms = map_match.group(3)
            if len(perms) < 3 or perms[2] != "x":
                continue
            raw_path = (map_match.group(5) or "").strip()
            if not raw_path:
                continue
            mappings.append(Mapping(
                start=int(map_match.group(1), 16),
                end=int(map_match.group(2), 16),
                perms=perms,
                offset=int(map_match.group(4), 16),
                path=raw_path,
                host_path=host_path_for(raw_path, repo_root),
            ))
    mappings.sort(key=lambda item: item.start)
    return mappings, threads


def find_mapping(addr: int, mappings: List[Mapping]) -> Optional[Mapping]:
    # The mapping list is small enough that a linear scan keeps this script simple.
    for item in mappings:
        if item.start <= addr < item.end:
            return item
    return None


def make_frame(addr: int, mappings: List[Mapping], main_binary: str, prefixes: List[Tuple[str, str]]) -> Frame:
    mapping = find_mapping(addr, mappings)
    if mapping is not None:
        object_addr = addr - mapping.start + mapping.offset
        object_label = display_path(mapping.path, prefixes)
        if mapping.host_path.startswith("[") or not os.path.exists(mapping.host_path):
            return Frame(addr, None, object_addr, object_label, "object not found on host")
        return Frame(addr, mapping.host_path, object_addr, object_label, "")

    # OceanBase's lbt formatting subtracts the main executable base for frames
    # inside the observer binary. These small addresses do not match /proc/maps,
    # but they are directly consumable by addr2line against the main binary.
    return Frame(addr, main_binary, addr, display_path(main_binary, prefixes), "main-relative")


def choose_addr2line(explicit: Optional[str]) -> Optional[str]:
    if explicit:
        return explicit
    return shutil.which("llvm-addr2line") or shutil.which("addr2line")


def symbolize_group(
    tool: str,
    object_path: str,
    object_addrs: List[int],
    timeout: int,
) -> Dict[int, str]:
    if not object_addrs:
        return {}
    unique_addrs = list(dict.fromkeys(object_addrs))
    cmd = [tool, "-Cfp", "-e", object_path] + [f"0x{addr:x}" for addr in unique_addrs]
    try:
        proc = subprocess.run(
            cmd,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return {addr: f"<symbolizer timeout after {timeout}s>" for addr in unique_addrs}

    if proc.returncode != 0:
        message = proc.stderr.strip() or f"<symbolizer exited {proc.returncode}>"
        return {addr: message for addr in unique_addrs}

    lines = [line.strip() for line in proc.stdout.splitlines() if line.strip()]
    result: Dict[int, str] = {}
    for addr, line in zip(unique_addrs, lines):
        result[addr] = line
    for addr in unique_addrs:
        result.setdefault(addr, "?? at ??:0")
    return result


def symbolize_frames(frames: List[Frame], tool: Optional[str], timeout: int) -> Dict[Tuple[str, int], str]:
    if tool is None:
        return {}
    by_object: Dict[str, List[int]] = {}
    for frame in frames:
        if frame.object_path is not None and frame.object_addr is not None:
            by_object.setdefault(frame.object_path, []).append(frame.object_addr)

    result: Dict[Tuple[str, int], str] = {}
    for object_path, object_addrs in by_object.items():
        object_result = symbolize_group(tool, object_path, object_addrs, timeout)
        for object_addr, symbol in object_result.items():
            result[(object_path, object_addr)] = symbol
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="Symbolize OceanBase kill -60 stack files.")
    parser.add_argument("--stack-file", required=True)
    parser.add_argument("--main-binary", required=True)
    parser.add_argument("--repo-root")
    parser.add_argument("--addr2line")
    parser.add_argument("--limit-threads", type=int, default=5)
    parser.add_argument("--limit-frames", type=int, default=12)
    parser.add_argument("--timeout", type=int, default=60)
    parser.add_argument("--display-prefix", action="append", type=parse_display_prefix, default=[])
    args = parser.parse_args()

    stack_file = os.path.abspath(args.stack_file)
    main_binary = os.path.abspath(args.main_binary)
    repo_root = os.path.abspath(args.repo_root) if args.repo_root else None

    prefixes: List[Tuple[str, str]] = list(args.display_prefix)
    if repo_root:
        prefixes.append((repo_root.rstrip("/"), "<repo>"))
        prefixes.append(("/work", "<repo>"))

    print("symbolized_thread_stack_sample:")
    print(f"stack_file={display_path(stack_file, prefixes)}")
    print(f"main_binary={display_path(main_binary, prefixes)}")

    if not os.path.exists(stack_file):
        print("status=SKIP reason=stack_file_missing")
        return 0
    if not os.path.exists(main_binary):
        print("status=SKIP reason=main_binary_missing")
        return 0

    tool = choose_addr2line(args.addr2line)
    print(f"symbolizer={tool or 'unavailable'}")
    if tool is None:
        print("status=SKIP reason=addr2line_missing")
        return 0

    mappings, threads = parse_stack_file(stack_file, repo_root)
    selected_threads = threads[:max(args.limit_threads, 0)]
    frames_by_thread: List[Tuple[ThreadStack, List[Frame]]] = []
    all_frames: List[Frame] = []
    for thread in selected_threads:
        frames = [
            make_frame(addr, mappings, main_binary, prefixes)
            for addr in thread.addrs[:max(args.limit_frames, 0)]
        ]
        frames_by_thread.append((thread, frames))
        all_frames.extend(frames)

    symbols = symbolize_frames(all_frames, tool, args.timeout)
    if not frames_by_thread:
        print("status=SKIP reason=no_thread_stack_lines")
        return 0

    for thread, frames in frames_by_thread:
        print(f"tid: {thread.tid}, tname: {thread.name}")
        for index, frame in enumerate(frames):
            object_addr = f"0x{frame.object_addr:x}" if frame.object_addr is not None else "?"
            note = f" ({frame.note})" if frame.note else ""
            print(f"  #{index:02d} 0x{frame.raw_addr:x} {frame.object_label}@{object_addr}{note}")
            if frame.object_path is not None and frame.object_addr is not None:
                symbol = symbols.get((frame.object_path, frame.object_addr), "?? at ??:0")
                print(f"      {display_text(symbol, prefixes)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

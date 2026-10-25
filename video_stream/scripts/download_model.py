"""Download one immutable EmbeddingGemma 2 snapshot using the standard library.

No model code is executed. LFS objects are SHA-256 verified; ordinary Git blobs
are verified using Git's blob SHA-1. Interrupted files retain a .download suffix.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import urllib.request

REPO = "google/embeddinggemma-2"


def verify(path, entry):
    size = entry["size"]
    if not path.is_file() or path.stat().st_size != size:
        return False
    if "lfs" in entry:
        digest, expected = hashlib.sha256(), entry["lfs"]["sha256"]
    else:
        digest, expected = hashlib.sha1(), entry["blobId"]
        digest.update(f"blob {size}\0".encode())
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest() == expected


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--destination", required=True)
    parser.add_argument("--revision", default="main", help="prefer an immutable model commit SHA")
    args = parser.parse_args()
    from urllib.parse import quote
    url = f"https://huggingface.co/api/models/{REPO}/revision/{quote(args.revision, safe='')}?blobs=true"
    with urllib.request.urlopen(url, timeout=60) as response:
        info = json.load(response)
    revision = info["sha"]
    destination = Path(args.destination).resolve()
    destination.mkdir(parents=True, exist_ok=True)
    entries = [entry for entry in info["siblings"] if entry["rfilename"] != ".gitattributes"]
    total = sum(entry["size"] for entry in entries)
    if shutil.disk_usage(destination).free < total + 1_000_000_000:
        raise RuntimeError("insufficient space for snapshot plus 1 GB free reserve")
    for entry in entries:
        relative = PurePosixPath(entry["rfilename"])
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("unsafe model filename")
        path = destination.joinpath(*relative.parts)
        if not path.resolve().is_relative_to(destination):
            raise ValueError("model path escapes destination")
        if verify(path, entry):
            print("verified", relative, flush=True)
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        partial = path.with_name(path.name + ".download")
        source = f"https://huggingface.co/{REPO}/resolve/{revision}/{quote(str(relative), safe='/')}"
        print("downloading", relative, entry["size"], "bytes", flush=True)
        with urllib.request.urlopen(source, timeout=120) as response, partial.open("wb") as output:
            shutil.copyfileobj(response, output, length=1024 * 1024)
        if not verify(partial, entry):
            raise RuntimeError(f"checksum mismatch: {relative}")
        partial.replace(path)
    (destination / "snapshot-revision.txt").write_text(revision + "\n")
    print("Snapshot verified. Set model_revision to:", revision, flush=True)


if __name__ == "__main__":
    main()

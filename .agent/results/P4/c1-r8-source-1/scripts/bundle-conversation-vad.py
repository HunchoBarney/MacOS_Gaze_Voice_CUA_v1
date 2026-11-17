import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import tempfile
import urllib.request


VAD_RECEIPT_SHA256 = "be41b15f2b6c5c73c4824b99963b54bc6d5f58c3af04468132ddfe131c1c8062"
RUNTIME = {
    "files": {
        "LICENSE": "2e63e9a38b6e8fc0c7bc37ce174caca1862870856c6daf5697cfb785e925520b",
        "README.md": "c31dbec3e24a014a51fc06c645b3cb04897c97ecdbad9a90645466019c933ef4",
        "silero-vad-unified-256ms-v6.2.1.mlmodelc/analytics/coremldata.bin": "8067594eb3126ab8318af507f0c00cabfed40d5fedb8a0ee5075dd02e903d909",
        "silero-vad-unified-256ms-v6.2.1.mlmodelc/coremldata.bin": "7db35a4fd995222a7fb0129713473b15d1462572ab4a2e5e4d56bcaad9e40f41",
        "silero-vad-unified-256ms-v6.2.1.mlmodelc/metadata.json": "2740be542c611e1ba358e1849b4e265c65cdf0b17192767e1e5de86a31ac94d6",
        "silero-vad-unified-256ms-v6.2.1.mlmodelc/model.mil": "c6a9d1bf22d413265da0a07a1d14151c3ea2fad296b3aa5859275b33ef1c3270",
        "silero-vad-unified-256ms-v6.2.1.mlmodelc/weights/weight.bin": "53ecc8b5081146140ab654c89109cf001f2183abddd7a2411c5081feeffff063",
    },
    "license": "MIT",
    "license_source": "https://raw.githubusercontent.com/snakers4/silero-vad/caddb3b7ce1dee88a14d5621a0e9a8fdeb2c2c48/LICENSE",
    "model": "silero-vad-unified-256ms-v6.2.1.mlmodelc",
    "repository": "FluidInference/silero-vad-coreml",
    "revision": "b419383c55c110e2c9271fa6ee0ea83d03c70d96",
    "schema": 1,
}


def check(condition, message):
    if not condition:
        raise ValueError(message)


def resource(base, relative):
    name = PurePosixPath(relative)
    check(relative and not name.is_absolute() and ".." not in name.parts, "escaped resource path")
    path = base / relative
    check(path.resolve().is_relative_to(base.resolve()), "escaped resource path")
    return path


def conversation_pin():
    pin = (json.dumps(RUNTIME, indent=2, sort_keys=True) + "\n").encode()
    check(hashlib.sha256(pin).hexdigest() == VAD_RECEIPT_SHA256, "conversation resource pin changed")
    return pin


def conversation_resource(base):
    pin = conversation_pin()
    document = resource(base, "resource.json")
    check(document.is_file(), "missing conversation resource: resource.json")
    check(document.read_bytes() == pin, "conversation resource manifest changed")
    metadata = json.loads(pin)
    for name, expected in metadata["files"].items():
        path = resource(base, name)
        check(path.is_file(), f"missing conversation resource: {name}")
        check(hashlib.sha256(path.read_bytes()).hexdigest() == expected, f"conversation resource changed: {name}")
    actual = {str(path.relative_to(base)) for path in base.rglob("*") if path.is_file()}
    check(actual == set(metadata["files"]) | {"resource.json"}, "unlisted conversation resources")
    return {"manifest_sha256": VAD_RECEIPT_SHA256, **metadata}


def prepare_conversation_resource(source, destination):
    if destination.exists():
        return conversation_resource(destination)
    check(destination.parent.is_dir(), "conversation resource parent is missing")
    with tempfile.TemporaryDirectory(prefix=".conversation-vad-", dir=destination.parent) as temporary:
        prepared = Path(temporary) / "resource"
        if source and source.is_dir():
            conversation_resource(source)
            shutil.copytree(source, prepared)
        else:
            pin = conversation_pin()
            metadata = json.loads(pin)
            prepared.mkdir()
            (prepared / "resource.json").write_bytes(pin)
            prefix = f"https://huggingface.co/{metadata['repository']}/resolve/{metadata['revision']}/"
            for name in metadata["files"]:
                target = resource(prepared, name)
                target.parent.mkdir(parents=True, exist_ok=True)
                url = metadata["license_source"] if name == "LICENSE" else prefix + name
                with urllib.request.urlopen(url, timeout=60) as response:
                    target.write_bytes(response.read())
        proof = conversation_resource(prepared)
        prepared.rename(destination)
        return proof


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--source", type=Path, default=os.environ.get("JEV_CONVERSATION_VAD_SOURCE"))
    args = parser.parse_args()
    destination = args.app / "Contents/Resources/ConversationVAD"
    print(json.dumps(prepare_conversation_resource(args.source, destination), sort_keys=True))


if __name__ == "__main__":
    main()

"""Prepare an owned arithmetic TFLite fixture; default is memory-only inspection.

This tests runtime plumbing, not ASL recognition. No TensorFlow installation,
training data, reference weights, or network access is required. The narrow
writer follows the public TFLite v3 schema, not a general FlatBuffers API.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct

FRAMES, CHANNELS, OUTPUTS = 64, 708, 50
FILENAME = "classifier_fixture_v1.tflite"
RECIPES = ("zeros", "ones", "ramp", "padded")


class Writer:
    def __init__(self):
        self.data = bytearray(b"\0\0\0\0TFL3")

    def align(self, alignment=4, offset=0):
        self.data.extend(b"\0" * (-(len(self.data) + offset) % alignment))

    def link(self, slot, target):
        if target <= slot:
            raise ValueError("Fixture references must point forward")
        struct.pack_into("<I", self.data, slot, target - slot)

    def table(self, fields):
        count = max(fields, default=-1) + 1
        self.align(2)
        vtable = len(self.data)
        self.data.extend(struct.pack("<HH", 4 + 2 * count, 4 + 4 * count))
        for index in range(count):
            self.data.extend(struct.pack("<H", 4 + 4 * index if index in fields else 0))
        self.align()
        table = len(self.data)
        self.data.extend(struct.pack("<i", table - vtable) + b"\0" * (4 * count))
        for index, value in fields.items():
            slot = table + 4 + 4 * index
            if callable(value):
                self.link(slot, value())
            else:
                struct.pack_into("<I", self.data, slot, value)
        return table

    def integers(self, values):
        self.align()
        start = len(self.data)
        self.data.extend(struct.pack("<I", len(values)))
        self.data.extend(struct.pack("<" + "i" * len(values), *values))
        return start

    def references(self, builders):
        start = self.integers([0] * len(builders))
        for index, builder in enumerate(builders):
            self.link(start + 4 + 4 * index, builder())
        return start

    def blob(self, value):
        # Buffer.data has force_align:16; align the data after its length word.
        self.align(16, offset=4)
        start = len(self.data)
        self.data.extend(struct.pack("<I", len(value)) + value)
        return start

    def string(self, value):
        self.align()
        value = value.encode("utf-8")
        start = len(self.data)
        self.data.extend(struct.pack("<I", len(value)) + value + b"\0")
        return start


def input_value(recipe, frame, channel):
    if recipe == "zeros":
        return 0.0
    if recipe == "ones":
        return 1.0
    if recipe == "ramp":
        return (channel % 17 - 8) / 8 + frame / 64
    if recipe == "padded":
        return 1.0 if frame < 48 else -100.0
    raise ValueError("Unknown fixture recipe")


def expected_output(recipe):
    # Independent closed-form means; do not simulate the model executor here.
    def mean(channel):
        return {"zeros": 0.0, "ones": 1.0, "padded": -24.25,
                "ramp": (channel % 17 - 8) / 8 + 63 / 128}[recipe]
    return [(1 if index % 2 == 0 else -1) * mean(index)
            + 0.5 * mean(CHANNELS - OUTPUTS + index) + index / 8
            for index in range(OUTPUTS)]


def build_model():
    writer = Writer()
    weights = [0.0] * (OUTPUTS * CHANNELS)
    for index in range(OUTPUTS):
        weights[index * CHANNELS + index] = 1.0 if index % 2 == 0 else -1.0
        weights[index * CHANNELS + CHANNELS - OUTPUTS + index] = 0.5
    buffers = [b"", struct.pack("<i", 1),
               struct.pack("<" + "f" * len(weights), *weights),
               struct.pack("<" + "f" * OUTPUTS, *(i / 8 for i in range(OUTPUTS)))]

    def tensor(shape, name, buffer=0, dtype=0):
        return writer.table({0: lambda: writer.integers(shape), 1: dtype, 2: buffer,
                             3: lambda: writer.string(name), 8: 1})

    def operator(code_index, inputs, outputs, option_type, options):
        return writer.table({0: code_index, 1: lambda: writer.integers(inputs),
                             2: lambda: writer.integers(outputs), 3: option_type,
                             4: lambda: writer.table(options)})

    def graph():
        tensors = [lambda: tensor([1, FRAMES, CHANNELS], "features"),
                   lambda: tensor([1], "time_axis", 1, 2),
                   lambda: tensor([1, CHANNELS], "mean_features"),
                   lambda: tensor([OUTPUTS, CHANNELS], "weights", 2),
                   lambda: tensor([OUTPUTS], "bias", 3),
                   lambda: tensor([1, OUTPUTS], "logits")]
        operators = [lambda: operator(0, [0, 1], [2], 27, {0: 0}),
                     lambda: operator(1, [2, 3, 4], [5], 8, {0: 0, 1: 0, 2: 0})]
        return writer.table({0: lambda: writer.references(tensors),
                             1: lambda: writer.integers([0]),
                             2: lambda: writer.integers([5]),
                             3: lambda: writer.references(operators),
                             4: lambda: writer.string("owned_arithmetic_fixture_v1")})

    codes = [lambda: writer.table({0: 40, 2: 1, 3: 40}),
             lambda: writer.table({0: 9, 2: 5, 3: 9})]
    root = writer.table({0: 3, 1: lambda: writer.references(codes),
                         2: lambda: writer.references([graph]),
                         3: lambda: writer.string("Runtime fixture; not an ASL model"),
                         4: lambda: writer.references([
                             lambda value=value: writer.table({0: lambda: writer.blob(value)})
                             if value else writer.table({}) for value in buffers])})
    struct.pack_into("<I", writer.data, 0, root)
    return bytes(writer.data)


def manifest(model):
    return {"version": 1, "purpose": "arithmetic runtime fixture; no sign labels",
            "filename": FILENAME, "bytes": len(model),
            "sha256": hashlib.sha256(model).hexdigest(),
            "inputShape": [1, FRAMES, CHANNELS], "outputShape": [1, OUTPUTS],
            "dtype": "float32", "operatorCodes": [40, 9], "operatorVersions": [1, 5],
            "absoluteTolerance": 0.00001, "relativeTolerance": 0.00001,
            "cases": [{"recipe": recipe, "expectedOutput": expected_output(recipe)}
                      for recipe in RECIPES]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="Only after asset approval: stage the owned fixture")
    args = parser.parse_args()
    model = build_model()
    metadata = manifest(model)
    if args.write:
        root = Path(__file__).resolve().parents[1] / ".build" / "classifier-fixture"
        paths = [(root / FILENAME, model),
                 (root / "manifest.json", (json.dumps(metadata, indent=2) + "\n").encode())]
        for path, contents in paths:
            if path.exists() and path.read_bytes() != contents:
                raise FileExistsError(f"Refusing to overwrite different contents: {path}")
        root.mkdir(parents=True, exist_ok=True)
        for path, contents in paths:
            if not path.exists():
                with path.open("xb") as output:
                    output.write(contents)
    print(json.dumps(metadata, indent=2))


if __name__ == "__main__":
    main()

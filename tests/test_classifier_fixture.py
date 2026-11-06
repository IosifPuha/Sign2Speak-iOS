"""Offline structural checks; these do not execute a native inference runtime."""
import math
import struct
import unittest

from flatbuffer_reader import FlatBuffer
from classifier_fixture import build_model, expected_output, input_value, manifest, RECIPES


class FixtureChecks(unittest.TestCase):
    def setUp(self):
        self.model = build_model()
        self.buffer = FlatBuffer(self.model)
        graphs = self.buffer.vector(self.buffer.root, 2)
        self.assertEqual(len(graphs), 1)
        self.graph = self.buffer.indirect(graphs[0])
        self.tensors = [self.buffer.indirect(x) for x in self.buffer.vector(self.graph, 0)]
        self.buffers = [self.buffer.indirect(x) for x in self.buffer.vector(self.buffer.root, 4)]

    def integers(self, table, field):
        return [self.buffer.scalar(x) for x in self.buffer.vector(table, field)]

    def blob(self, index):
        slot = self.buffer.field(self.buffers[index], 0)
        start = self.buffer.indirect(slot)
        size = self.buffer.scalar(start, "I")
        self.assertEqual((start + 4) % 16, 0)
        return self.model[start + 4:start + 4 + size]

    def test_determinism_and_contract(self):
        self.assertEqual(build_model(), self.model)
        self.assertEqual(self.buffer.default(self.buffer.root, 0), 3)
        self.assertEqual(self.integers(self.graph, 1), [0])
        self.assertEqual(self.integers(self.graph, 2), [5])
        self.assertEqual(self.integers(self.tensors[0], 0), [1, 64, 708])
        self.assertEqual(self.integers(self.tensors[5], 0), [1, 50])
        codes = [self.buffer.indirect(x) for x in self.buffer.vector(self.buffer.root, 1)]
        self.assertEqual([self.buffer.default(x, 3) for x in codes], [40, 9])
        self.assertEqual([self.buffer.default(x, 2) for x in codes], [1, 5])
        operations = [self.buffer.indirect(x) for x in self.buffer.vector(self.graph, 3)]
        self.assertEqual([self.integers(x, 1) for x in operations], [[0, 1], [2, 3, 4]])
        self.assertEqual([self.integers(x, 2) for x in operations], [[2], [5]])
        self.assertEqual([self.buffer.default(x, 3, "B") for x in operations], [27, 8])
        self.assertEqual(self.buffer.default(self.tensors[1], 1, "B"), 2)
        self.assertEqual(struct.unpack("<i", self.blob(1)), (1,))

    def test_serialized_weights_match_independent_expected_outputs(self):
        weights = struct.unpack("<" + "f" * (50 * 708), self.blob(2))
        biases = struct.unpack("<" + "f" * 50, self.blob(3))
        for recipe in RECIPES:
            means = [math.fsum(input_value(recipe, t, c) for t in range(64)) / 64
                     for c in range(708)]
            actual = [math.fsum(w * x for w, x in zip(weights[k * 708:(k + 1) * 708], means))
                      + biases[k] for k in range(50)]
            self.assertEqual(actual, expected_output(recipe))
            self.assertTrue(all(math.isfinite(x) for x in actual))
        metadata = manifest(self.model)
        self.assertEqual(metadata["bytes"], len(self.model))
        self.assertEqual(len(metadata["sha256"]), 64)
        self.assertEqual([x["recipe"] for x in metadata["cases"]], list(RECIPES))


if __name__ == "__main__":
    unittest.main()

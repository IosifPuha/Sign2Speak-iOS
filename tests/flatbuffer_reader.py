"""Small independent TFLite reader for offline fixture checks."""
import struct


class FlatBuffer:
    def __init__(self, data):
        if data[4:8] != b"TFL3":
            raise ValueError("Not a TFLite model (possibly an unresolved LFS pointer)")
        self.data = data
        self.root = self.scalar(0, "I")

    def scalar(self, offset, kind="i"):
        if offset < 0 or offset + struct.calcsize("<" + kind) > len(self.data):
            raise ValueError("Invalid FlatBuffer offset")
        return struct.unpack_from("<" + kind, self.data, offset)[0]

    def field(self, table, index):
        vtable = table - self.scalar(table)
        entry = 4 + 2 * index
        offset = self.scalar(vtable + entry, "H") if entry < self.scalar(vtable, "H") else 0
        return table + offset if offset else None

    def indirect(self, offset):
        return offset + self.scalar(offset, "I")

    def vector(self, table, field):
        position = self.field(table, field)
        if position is None:
            return []
        start = self.indirect(position)
        count = self.scalar(start, "I")
        if count > len(self.data) // 4:
            raise ValueError("Invalid vector length")
        return [start + 4 + 4 * i for i in range(count)]

    def default(self, table, field, kind="i", value=0):
        position = self.field(table, field)
        return value if position is None else self.scalar(position, kind)

    def string(self, table, field):
        position = self.field(table, field)
        if position is None:
            return None
        start = self.indirect(position)
        size = self.scalar(start, "I")
        if start + 4 + size > len(self.data):
            raise ValueError("Invalid string length")
        return self.data[start + 4:start + 4 + size].decode("utf-8")


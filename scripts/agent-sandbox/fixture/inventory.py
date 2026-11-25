"""Tiny inventory service."""


class Inventory:
    def __init__(self):
        self._items = {}

    def add(self, sku, qty):
        self._items[sku] = self._items.get(sku, 0) + qty

    def remove(self, sku, qty):
        self._items[sku] = self._items.get(sku, 0) - qty

    def count(self, sku):
        return self._items.get(sku, 0)

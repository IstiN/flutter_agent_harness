import unittest

from inventory import Inventory


class InventoryTest(unittest.TestCase):
    def test_add_and_count(self):
        inv = Inventory()
        inv.add("a", 3)
        inv.add("a", 2)
        self.assertEqual(inv.count("a"), 5)

    def test_remove(self):
        inv = Inventory()
        inv.add("a", 3)
        inv.remove("a", 1)
        self.assertEqual(inv.count("a"), 2)

    def test_cannot_remove_more_than_stock(self):
        inv = Inventory()
        inv.add("a", 1)
        with self.assertRaises(ValueError):
            inv.remove("a", 2)
        self.assertEqual(inv.count("a"), 1)


if __name__ == "__main__":
    unittest.main()

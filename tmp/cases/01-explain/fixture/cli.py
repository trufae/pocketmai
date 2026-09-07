import sys
from inventory import Inventory, Item, format_report, low_stock


def load(path: str) -> Inventory:
    inventory = Inventory()
    with open(path) as fh:
        for line in fh:
            sku, name, qty, price = line.strip().split(",")
            inventory.add(Item(sku, name, int(qty), float(price)))
    return inventory


def main(argv):
    inventory = load(argv[1])
    print(format_report(inventory))
    for item in low_stock(inventory):
        print(f"warning: {item.name} is low ({item.quantity})")


if __name__ == "__main__":
    main(sys.argv)

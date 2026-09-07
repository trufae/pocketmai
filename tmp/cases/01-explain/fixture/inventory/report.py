from .store import Inventory


def low_stock(inventory: Inventory, threshold: int = 5):
    return [item for item in inventory.items.values() if item.quantity < threshold]


def format_report(inventory: Inventory) -> str:
    lines = [f"{'SKU':8} {'Name':20} {'Qty':>5} {'Value':>10}"]
    for item in sorted(inventory.items.values(), key=lambda i: i.sku):
        lines.append(f"{item.sku:8} {item.name:20} {item.quantity:>5} {item.value():>10.2f}")
    lines.append(f"Total value: {inventory.total_value():.2f}")
    return "\n".join(lines)

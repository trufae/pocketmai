from dataclasses import dataclass, field


@dataclass
class Item:
    sku: str
    name: str
    quantity: int = 0
    unit_price: float = 0.0

    def value(self) -> float:
        return self.quantity * self.unit_price


@dataclass
class Inventory:
    items: dict = field(default_factory=dict)

    def add(self, item: Item) -> None:
        existing = self.items.get(item.sku)
        if existing:
            existing.quantity += item.quantity
        else:
            self.items[item.sku] = item

    def remove(self, sku: str, quantity: int) -> None:
        item = self.items[sku]
        if quantity > item.quantity:
            raise ValueError(f"only {item.quantity} of {sku} in stock")
        item.quantity -= quantity
        if item.quantity == 0:
            del self.items[sku]

    def total_value(self) -> float:
        return sum(item.value() for item in self.items.values())

# pipeline API

- `fetch_data(path)`: read a CSV file into a list of dicts.
- `normalize(rows)`: strip whitespace and lower-case the keys.
- `write_data(path, rows)`: write rows back to CSV.

Example:

```python
from pipeline import fetch_data, normalize
rows = normalize(fetch_data("input.csv"))
```

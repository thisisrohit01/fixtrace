# FixTrace 🔧

Track the full repair history of phones, laptops and tablets, and see an estimated resale value and profit/loss for each device.

## Features
- Dashboard: total devices, total invested, estimated resale value, projected profit/loss
- Per-device repair log with parts replaced, part quality (OEM / Aftermarket / Unknown) and costs
- Automatic resale estimate based on market price or depreciated launch price, condition grade, battery health and part quality
- Warranty tracking: device warranty (start date + months) and per-part warranty (months from the repair date), with Active / Expiring / Expired badges
- Parts & warranty claims section: store the serial number of each replaced part, then file a claim (needs a serial number) and track it as Filed / Approved / Rejected with a ticket note
- Data saved in your browser (localStorage); JSON export button for backups

## Run it
No build step and no dependencies. Open `index.html` in any browser.

To host it free on GitHub Pages: push the repo, then go to **Settings → Pages**, choose the `main` branch and `/ (root)`.

## Database schema
`database/schema.sql` is a SQL design (SQLite-compatible, easy to port to PostgreSQL/MySQL) with tables for devices, repairs, parts, repair_parts, valuations, sales and warranty_claims, plus overview views. The current web app does not use it yet; it is the blueprint for a future backend so data can sync across devices.

```bash
sqlite3 fixtrace.db < database/schema.sql
sqlite3 fixtrace.db "SELECT * FROM v_device_overview;"
```

## Resale estimate formula
```
base     = market price of similar device, or launch price × 0.78^years
estimate = base × condition (A 1.0, B 0.9, C 0.75, D 0.55)
              × battery factor (0.95 if health < 80%)
              × part-quality penalty (OEM 0.99, Unknown 0.98, Aftermarket 0.97 per part)
```

Warranty does not change the resale estimate; it is tracked separately.

## Roadmap
- Backend using `database/schema.sql` (sync across devices)
- Customers and invoices for repair shops
- Photos and printable device report

## License
MIT

### Changed
- Console, dashboard, pages and drive source comments now state current invariants instead of ticket and incident history, and dead dashboard code is gone.

### Removed
- The dashboard's unused Factory view assets (`/factory.js`, `/factory.css`), the retired `GET /api/v2/forecast` feed (the Usage card replaced it), and the uncalled `POST /api/inbox-resolve` and `POST /api/ticket-state` endpoints.

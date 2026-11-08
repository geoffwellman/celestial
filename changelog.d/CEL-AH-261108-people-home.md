### Added
- `people:` in `workspace.yaml` names who is on a team workspace: an id, their own forge login, and roles (`owner`, `product-lead`, `qa`, `design`, `release`, `approver`) held workspace-wide or per product.
- `me: <id>` in a login's gitignored `workspace.local.yaml` says which person that login is. It is the one key the local file may set besides routing; a `me:` committed to `workspace.yaml` is ignored, and `cel doctor` reports it as an error.
- `products[].home: <id>` (or `repos[].home` for a repo in no product) names the person whose login runs the product's agents. On any other login, `cel run orchestrator|solo --product <p>`, lanes included, refuses (`cel run: atlas runs on sam's login (products[].home: sam); this login is jo - ask sam, or pass --force`), and `cel ws up` and the steward skip the product without raising anything. A login with no `me:` starts no product that has a home.
- `cel people [--workspace w] [--json]` lists the people, their logins and roles, which person this login is, and which login runs each product.
- `cel doctor` checks `people:` (unique ids, id and login format, roles from the fixed list, products that exist), that `me:` and every `home:` name a person, and warns when `me:`'s login is not this login's own forge account, when a login has no `me:` but products have a home, and when a `kind: team` workspace has an `orchestrator: auto` product with no home.

### Changed
- `workspace.local.example.yaml`, written by `cel ws new`, offers `me:`.
- `cel ws up --dry-run` and `cel ws status` name the home login of a product they will not start on this login.

### Fixed
- Nothing.

### Removed
- Nothing.

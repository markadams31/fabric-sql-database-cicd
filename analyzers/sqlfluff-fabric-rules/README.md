# sqlfluff-fabric-rules

Custom SQLFluff style rules for the reference solution — the source-text counterpart to the
model-level DacFx rules in [`../FabricSqlRules`](../FabricSqlRules). A worked example of adding
a project-specific SQLFluff rule as a plugin.

## The rule

- **`Fabric_L001`** — `fabric.unicode_string_literals` (alias `FAB01`): string literals must be
  Unicode (`N'...'`). This platform is `NVARCHAR`/Entra-first; a non-`N` literal forces an
  implicit conversion, and against an indexed `NVARCHAR` column that can turn a seek into a
  scan. `N'Pending'` passes; `'Pending'` is flagged.

## How it plugs in

SQLFluff discovers the rule through the `sqlfluff` entry point in `pyproject.toml` once the
package is installed into the same environment as SQLFluff:

```sh
pip install sqlfluff==4.2.2 -e ./analyzers/sqlfluff-fabric-rules
```

Then `sqlfluff lint databases` runs it alongside the built-in rules (it's in the `all` group). CI
installs it in the lint step, and the pre-commit hook runs SQLFluff from your environment, so
both pick it up. Rule selection and severities live in [`../../.sqlfluff`](../../.sqlfluff),
the same as the built-in rules.

## Adding another rule

1. Add a `Rule_Fabric_Lxxx` class to `src/sqlfluff_fabric_rules/rules.py` — subclass
   `BaseRule`, set `name` / `groups` / `crawl_behaviour`, implement `_eval` returning a
   `LintResult` per violation.
2. Return it from `get_rules()` in `src/sqlfluff_fabric_rules/__init__.py`.

# Conventions

Every convention here is either a build check or — where a check is a warning your team
escalates, or no reliable check exists — the pattern the example schema follows. This page
answers: what does the build check, and how do you add or change a rule?

## Two layers of enforcement

Validation is two standard commands. Each sees the schema differently, which is why there are
two:

- **SQLFluff lints the source text.** `sqlfluff lint databases` reads the raw `.sql` files
  before anything compiles, so it governs what lives in the text: keyword casing, line length,
  layout. The active style rules are in [.sqlfluff](../.sqlfluff). It runs first because it is
  the cheapest check — a casing slip fails in seconds.
- **The build analyzes the parsed model.** `dotnet build build.proj` compiles every SQL project
  into a dacpac and runs code-analysis rules against the typed model, catching structural
  defects text linting cannot see: a table with no primary key, an unindexed foreign key,
  `SELECT *` in a view. Before any rule runs, the projects compile against the
  SQL-database-in-Fabric target platform, so unsupported T-SQL fails outright.

Git hooks run both locally (lint on commit, build on push —
[local-development.md](local-development.md)), and
[pr-validation.yml](../.github/workflows/pr-validation.yml) runs the same two on every PR as
the authoritative gate. No gate depends on running a check by hand.

## The rule set lives in one place

Code analysis draws on three sources, wired in
[databases/Directory.Build.props](../databases/Directory.Build.props) so every SQL project
inherits them:

- **Built-in DacFx rules** — shipped with the SQL build tooling.
- **A community rule set** (`ErikEJ.DacFX.SqlServer.Rules`) — general structural conventions:
  missing primary key, unindexed foreign key, deprecated types, and many more.
- **This repo's custom rules** in [analyzers/FabricSqlRules](../analyzers/FabricSqlRules) — a
  C# class library referenced as an analyzer, for organization conventions no off-the-shelf
  rule expresses.

Which rules run and at what severity is one property — `SqlCodeAnalysisRules` in
`Directory.Build.props`, the source of truth this page deliberately does not duplicate. The
split it encodes:

- **Platform and anti-pattern rules run as build errors** — `SELECT *`, `WAITFOR`, and the like
  fail the build. These are defects, not house style.
- **This repo's convention rules run as warnings** — visible on every build without the
  day-one friction of retrofitting an estate. A team that has adopted a convention escalates
  its rule to an error in one line.

The syntax: `+!<RuleId>` escalates a rule to a build error; `-<RuleId>` disables one (used for
rules that recommend settings Fabric manages, or that assume design choices these projects
don't make). Because the config is shared, changing what the estate enforces is a one-line
edit applied to every database at once.

## Custom rules

Three ship in [analyzers/FabricSqlRules](../analyzers/FabricSqlRules), all as warnings:

- **Audit columns present** — every table carries the standard audit columns
  ([below](#audit-columns)).
- **Audit trigger present** — each table has an audit trigger. Existence only: a trigger that
  does the wrong thing still passes; correctness is a review concern.
- **Bounded string and binary columns** — bans `MAX` on string/binary types, so unbounded
  columns are a deliberate exception rather than a default. It catches `MAX` specifically; a
  bare `NVARCHAR` with no length passes the rule and is caught by the written convention below.

## Adding a convention

A convention worth codifying becomes a rule, not a wiki page:

1. Write a DacFx code-analysis rule in [analyzers/FabricSqlRules](../analyzers/FabricSqlRules)
   — a class deriving from `SqlCodeAnalysisRule` that inspects the typed `TSqlModel` and
   returns one problem per violation.
   [AuditColumnsRule.cs](../analyzers/FabricSqlRules/AuditColumnsRule.cs) is a complete minimal
   example; for the DacFx analysis API itself see
   [ErikEJ's guide](https://erikej.github.io/dacfx/codeanalysis/sqlserver/2024/04/02/dacfx-codeanalysis.html).
2. Reference the rule's ID in `SqlCodeAnalysisRules` — warning severity to introduce it gently,
   `+!` to gate the build.

Source-*text* conventions go to SQLFluff instead: a built-in rule is a setting in
[.sqlfluff](../.sqlfluff); one it doesn't cover is a custom rule in
[analyzers/sqlfluff-fabric-rules](../analyzers/sqlfluff-fabric-rules) (the shipped example
requires Unicode `N'...'` literals). Some conventions are expressible in neither layer —
grants-target-roles is review-enforced ([security.md](security.md)).

## Naming and layout

Layout exists so a reviewer can find any object from its name, and so a diff touches exactly
what it changes. A database is a `databases/<name>/` folder
([databases/AppDb](../databases/AppDb) is the example); inside it:

- **One file per object**, file name = object name. The SQL files are the schema; there is no
  separate manifest.
- **Grouped by type** — `Tables/`, `Triggers/`, `Security/`, and so on.
- **Scripts live apart from schema.** `Scripts/PostDeployment/` and `Scripts/DataMigrations/`
  hold deployment logic and are excluded from the compiled model — which is also why a data
  migration may use `WAITFOR` although the analyzer bans it in schema.
- **Schema-qualified names.** Every object lives in an explicit schema and is referenced
  two-part (`app.Order`, not `Order`).
- **Surrogate keys** by design — which is why the community natural-key rule is disabled.
- **Explicit lengths on string types.** `NVARCHAR(200)`, never bare `NVARCHAR` (which silently
  defaults and truncates later). A written convention: the bounded-strings rule bans `MAX`, but
  a bare length is on reviewers to catch.
- **Add new columns at the end of the table.** SqlPackage preserves declared column order:
  inserting a column between existing ones makes the publish rebuild the whole table — copy
  every row into a new table and swap — instead of a cheap metadata `ALTER … ADD`. Audit
  columns sit last by convention, so append new business columns after them; a mid-table
  insert costs a rebuild (with its lock and timeout risk) in every environment.

## Audit columns

Every table carries four audit columns — `CreatedAt`, `CreatedBy`, `ModifiedAt`, `ModifiedBy` —
nullable, `DATETIME2`, populated by one `AFTER INSERT, UPDATE` trigger per table
(`app.trg_<Table>_Audit`) using `ORIGINAL_LOGIN()` and `SYSUTCDATETIME()`. A trigger rather
than `DEFAULT` constraints because it captures the real caller and a consistent UTC clock on
both insert and update, which per-column defaults cannot do for the modified pair. Two custom
rules back the convention (columns exist, trigger exists); trigger *correctness* is a review
concern.

## Security in the schema

Permissions are code: roles, schemas, and grants live in `databases/<name>/Security/` and
deploy with everything else (`IgnorePermissions=False` — [ci-cd.md](ci-cd.md)). Grants target
roles, never individuals, and `DENY` always wins. The full access model — both layers, the
principals, the scoped-reader chain — is in [security.md](security.md).

## Post-deployment scripts

`Scripts/PostDeployment/` runs on every publish (a no-op leg skipped by the deploy's
source-hash check publishes nothing — [ci-cd.md](ci-cd.md)), so every statement must be idempotent and
state-guarded: check the live state, apply only if it differs. The shape, on a database-scoped
setting:

```sql
-- Guarded: apply only when the live value differs from intent.
IF EXISTS (
    SELECT 1
    FROM sys.database_scoped_configurations
    WHERE name = N'MAXDOP' AND CONVERT(int, value) <> 8
)
BEGIN
    ALTER DATABASE SCOPED CONFIGURATION SET MAXDOP = 8;
END;
```

The guard makes the script a statement of desired state: against a database already in the
right state it does nothing; against a fresh one it converges. That is what lets the same
script run unmodified on every publish. The shipped example provisions the scoped reader's
contained user ([security.md](security.md#the-scoped-reader-chain)).

`Scripts/DataMigrations/` holds backfills and large rewrites — batched, idempotent, verified,
pruned once applied. The playbook is [data-migrations.md](data-migrations.md).

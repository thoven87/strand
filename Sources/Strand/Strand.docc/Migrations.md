# Schema migrations

Managing the `strand.sql` schema across deployments.

## The current model

`strand.sql` is a single file that creates the complete `strand` schema from
scratch. Apply it once against a fresh database:

```bash
psql "postgresql://user:pass@host/db" -f strand.sql
```

For local development and new deployments this is sufficient. For running
production databases that already have the schema, adding any new column
requires a separate targeted migration — re-running `strand.sql` would fail
on the `CREATE TABLE` statements that already exist.

## What goes wrong without migrations

When Strand adds a new column (for example `deadline_at` on `strand.tasks` or
`timeout_seconds` on `strand.tasks`), a worker built against the new SDK
version will issue SQL that references those columns. Any worker process running
against an un-migrated database will get a Postgres error at the first claim
attempt:

```
ERROR: column "deadline_at" does not exist
```

`verifySchema()` currently only checks that `strand.tasks` exists — it does not
verify column presence or a schema version number, so the error surfaces at
runtime rather than at startup.

## Recommended approach: `postgres-migrations`

[`postgres-migrations`](https://github.com/hummingbird-project/postgres-migrations)
by the Hummingbird project provides a `DatabaseMigration` protocol and a
`DatabaseMigrationService` that integrates directly with `ServiceLifecycle`.
It tracks applied migrations in a `_hb_migrations` table and is idempotent —
running it twice applies only the unapplied steps.

### 1. Add the dependency

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/hummingbird-project/postgres-migrations", from: "0.4.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "PostgresMigrations", package: "postgres-migrations"),
        .product(name: "Strand", package: "strand"),
    ]),
]
```

### 2. Wrap the initial schema as migration 0

```swift
import PostgresMigrations
import PostgresNIO
import Logging

/// Applies the full strand schema on a fresh database.
/// Never changes after release — subsequent schema changes become new migrations.
struct CreateStrandSchema: DatabaseMigration {
    func apply(connection: PostgresConnection, logger: Logger) async throws {
        // strand.sql content inlined or loaded from a bundle resource.
        let sql = try String(contentsOf: Bundle.module.url(forResource: "strand", withExtension: "sql")!)
        try await connection.query(.init(unsafeSQL: sql), logger: logger)
    }

    func revert(connection: PostgresConnection, logger: Logger) async throws {
        try await connection.query("DROP SCHEMA strand CASCADE", logger: logger)
    }
}
```

### 3. Add new columns as subsequent migrations

Each schema change shipped with a new Strand version becomes its own
numbered migration:

```swift
/// Added in Strand 0.2: per-attempt execution deadline.
struct AddTimeoutSecondsToTasks: DatabaseMigration {
    func apply(connection: PostgresConnection, logger: Logger) async throws {
        try await connection.query(
            "ALTER TABLE strand.tasks ADD COLUMN IF NOT EXISTS timeout_seconds INTEGER",
            logger: logger)
    }

    func revert(connection: PostgresConnection, logger: Logger) async throws {
        try await connection.query(
            "ALTER TABLE strand.tasks DROP COLUMN IF EXISTS timeout_seconds",
            logger: logger)
    }
}

/// Added in Strand 0.2: total wall-clock deadline across all retries.
struct AddDeadlineAtToTasks: DatabaseMigration {
    func apply(connection: PostgresConnection, logger: Logger) async throws {
        try await connection.query(
            "ALTER TABLE strand.tasks ADD COLUMN IF NOT EXISTS deadline_at TIMESTAMPTZ",
            logger: logger)
        try await connection.query(
            """
            CREATE INDEX IF NOT EXISTS strand_tasks_deadline_idx
                ON strand.tasks (namespace_id, queue, deadline_at)
                WHERE deadline_at IS NOT NULL AND state = 'PENDING'
            """,
            logger: logger)
    }

    func revert(connection: PostgresConnection, logger: Logger) async throws {
        try await connection.query(
            "DROP INDEX IF EXISTS strand_tasks_deadline_idx", logger: logger)
        try await connection.query(
            "ALTER TABLE strand.tasks DROP COLUMN IF EXISTS deadline_at", logger: logger)
    }
}
```

### 4. Wire into the ServiceGroup

`DatabaseMigrationService` conforms to `Service`. ServiceLifecycle runs it to
completion before the other services are considered "ready" — because it
finishes after `apply()` and then calls `gracefulShutdown()` to let the group
know it is done:

```swift
import PostgresMigrations
import ServiceLifecycle

var migrations = DatabaseMigrations()
migrations.add(CreateStrandSchema())
migrations.add(AddTimeoutSecondsToTasks())
migrations.add(AddDeadlineAtToTasks())

let migrationService = DatabaseMigrationService(
    client: postgres,
    migrations: migrations,
    logger: logger,
    dryRun: false
)

let group = ServiceGroup(configuration: .init(
    services: [
        // Migration service runs first and signals completion.
        .init(service: migrationService,
              successTerminationBehavior: .ignore,
              failureTerminationBehavior: .gracefullyShutdownGroup),
        .init(service: postgres),
        .init(service: worker),
        .init(service: scheduler),
    ],
    gracefulShutdownSignals: [.sigterm, .sigint],
    logger: logger
))
try await group.run()
```

With `successTerminationBehavior: .ignore` the group keeps running after
migrations finish. With `failureTerminationBehavior: .gracefullyShutdownGroup`
a migration failure shuts the whole application down before any worker begins
processing.

## Future work

Strand should ship its own versioned migration set built on top of
`postgres-migrations` so that applications only need to add the migration
service — the per-column migrations are distributed with the library rather
than written by each consumer. Tracked as a future enhancement.

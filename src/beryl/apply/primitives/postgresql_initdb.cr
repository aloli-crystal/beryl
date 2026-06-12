require "../primitive"

module Beryl::Apply
  # Primitive `postgresql-initdb` : initialise le cluster PostgreSQL via
  # `service postgresql initdb`. PostgreSQL l'exige avant le premier start
  # (MariaDB s'auto-initialise, lui). Idempotente et auto-gardée : skip si
  # un data dir est déjà initialisé (`/var/db/postgres/data*/PG_VERSION`).
  # Capacité ÉTROITE : initialiser le cluster, rien d'autre.
  #
  #     - postgresql-initdb: {}
  class PostgresqlInitdb < Primitive
    def name : String
      "postgresql-initdb"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      # Pas de serveur PostgreSQL installé (ex. only: client) → rien à
      # initialiser, et `service postgresql initdb` échouerait.
      unless shell.exec("test -f /usr/local/etc/rc.d/postgresql", raise_on_error: false).success?
        return StepResult.skipped("serveur PostgreSQL non installé — initdb ignoré")
      end

      initialized = shell.exec(
        "ls /var/db/postgres/data*/PG_VERSION >/dev/null 2>&1",
        raise_on_error: false,
      ).success?
      return StepResult.skipped("cluster PostgreSQL déjà initialisé") if initialized
      return StepResult.applied("initdb (dry-run)") if dry_run

      shell.exec("service postgresql initdb")
      StepResult.applied("cluster PostgreSQL initialisé")
    end
  end

  Primitive.register(PostgresqlInitdb.new)
end

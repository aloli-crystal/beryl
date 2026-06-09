require "option_parser"
require "secrets"
require "toml"
require "../config"
require "../xdg"
require "./config_git"

# `beryl env` — gestion des credentials chiffrés par société.
#
# Trois sous-commandes :
#
#   migrate [<société>...]  Convertit `.env.yml[société]` en
#                           `<société>/.env.toml.age` chiffré.
#   edit <société>          Ouvre le coffre dans $EDITOR, re-chiffre.
#   show <société>          Affiche le plaintext (debug, hors prod).
#
# Le coffre est chiffré au roster global `secrets`
# (`~/.config/secrets/recipients.toml`) — un roster par société
# viendra quand `Secrets::Recipients` acceptera un path optionnel.
module Beryl::CLI::Env
  extend self

  USAGE = <<-USAGE
    USAGE : beryl env <SOUS-COMMANDE> [args]

    SOUS-COMMANDES :
      migrate [<société>...]    Migre .env.yml[société] vers <société>/.env.toml.age
      edit <société>            Édite le coffre d'une société dans $EDITOR
      show <société>            Affiche le plaintext du coffre (debug, à éviter en prod)

    Le coffre est chiffré au roster `secrets` global. Lancer
    `secrets init` une fois sur ce poste si ce n'est pas déjà fait.
    USAGE

  # Point d'entrée appelé par `cli.cr`.
  def run(config_root : String, argv : Array(String)) : Int32
    if argv.empty? || argv.first == "--help" || argv.first == "-h" || argv.first == "help"
      STDOUT.puts USAGE
      return 0
    end

    sub = argv.first
    rest = argv[1..-1]
    case sub
    when "migrate" then cmd_migrate(config_root, rest)
    when "edit"    then cmd_edit(config_root, rest)
    when "show"    then cmd_show(config_root, rest)
    else
      STDERR.puts "beryl env : sous-commande inconnue : #{sub}"
      STDERR.puts USAGE
      64
    end
  end

  # ─────────────────────────────────────────────────────────────
  # migrate
  # ─────────────────────────────────────────────────────────────

  private def self.cmd_migrate(config_root : String, argv : Array(String)) : Int32
    force = false
    purge = false
    no_commit = false
    OptionParser.parse(argv.dup) do |parser|
      parser.banner = "USAGE : beryl env migrate [--force] [--purge-yaml] [<société>...]"
      parser.on("-f", "--force", "Écrase un coffre destination déjà présent (DANGEREUX)") { force = true }
      parser.on("-p", "--purge-yaml", "Supprime la section migrée de .env.yml après écriture du coffre") { purge = true }
      parser.on("--no-commit", "N'auto-commite pas le coffre chiffré dans le dépôt git de config") { no_commit = true }
      parser.on("-h", "--help", "Affiche cette aide") { puts parser; exit 0 }
    end
    only = argv.reject { |a| a.starts_with?("-") }

    env_yml_path = File.join(config_root, ".env.yml")
    unless File.exists?(env_yml_path)
      STDERR.puts "beryl env migrate : aucun #{env_yml_path} à migrer."
      return 1
    end

    env_file = Beryl::Config::EnvFile.load(env_yml_path)
    accounts_to_migrate = only.empty? ? env_file.accounts : only
    if accounts_to_migrate.empty?
      STDERR.puts "beryl env migrate : aucune société à migrer (le .env.yml est vide)."
      return 0
    end

    migrated = [] of String
    skipped = [] of String
    failed = [] of String

    accounts_to_migrate.each do |account|
      providers = env_file.for_account(account)
      if providers.empty?
        STDERR.puts "[#{account}] aucune section dans .env.yml — ignorée."
        skipped << account
        next
      end

      account_dir = File.join(config_root, account)
      unless File.directory?(account_dir)
        STDERR.puts "[#{account}] le dossier #{account_dir} n'existe pas. Créez-le d'abord (`beryl add-domain #{account}/<domaine>`)."
        failed << account
        next
      end

      vault_path = File.join(account_dir, Beryl::Config::EnvFile::VAULT_FILENAME)
      if File.exists?(vault_path) && !force
        STDERR.puts "[#{account}] #{vault_path} existe déjà — passez `--force` pour écraser."
        skipped << account
        next
      end

      begin
        Beryl::Config::EnvFile.write_vault(vault_path, providers)
      rescue ex
        STDERR.puts "[#{account}] échec de l'écriture du coffre : #{ex.message}"
        failed << account
        next
      end

      migrated << account
      STDOUT.puts "[#{account}] #{providers.size} provider(s) → #{vault_path}"

      # Le coffre `.env.toml.age` est chiffré → commitable. Auto-commit
      # dans le dépôt de config société (un par société, chacun dans son
      # propre dépôt).
      Beryl::CLI::ConfigGit.commit(
        [vault_path],
        "env : coffre #{account} mis à jour (migrate)",
        no_commit,
      )

      if purge
        env_file.clear_account(account)
      end
    end

    if purge && !migrated.empty?
      env_file.save
      STDOUT.puts "[migrate] sections migrées supprimées de #{env_yml_path}"
    end

    STDOUT.puts
    STDOUT.puts "[migrate] #{migrated.size} migré(s), #{skipped.size} ignoré(s), #{failed.size} en échec"
    if !migrated.empty? && !purge
      STDOUT.puts "[migrate] note : .env.yml n'a pas été modifié. Relancez avec `--purge-yaml` pour"
      STDOUT.puts "                supprimer les sections migrées (le coffre fait autorité au load)."
    end

    failed.empty? ? 0 : 1
  end

  # ─────────────────────────────────────────────────────────────
  # edit
  # ─────────────────────────────────────────────────────────────

  private def self.cmd_edit(config_root : String, argv : Array(String)) : Int32
    account = ""
    create = false
    no_commit = false
    OptionParser.parse(argv.dup) do |parser|
      parser.banner = "USAGE : beryl env edit [--create] <société>"
      parser.on("-c", "--create", "Crée un coffre vide si absent") { create = true }
      parser.on("--no-commit", "N'auto-commite pas le coffre chiffré dans le dépôt git de config") { no_commit = true }
      parser.on("-h", "--help", "Affiche cette aide") { puts parser; exit 0 }
    end
    positional = argv.reject { |a| a.starts_with?("-") }
    account = positional.first if positional.size >= 1

    if account.empty?
      STDERR.puts "beryl env edit : argument <société> manquant."
      return 64
    end

    account_dir = File.join(config_root, account)
    unless File.directory?(account_dir)
      STDERR.puts "beryl env edit : la société `#{account}` n'a pas de dossier (#{account_dir} absent)."
      return 1
    end

    vault_path = File.join(account_dir, Beryl::Config::EnvFile::VAULT_FILENAME)
    plaintext_before = if File.exists?(vault_path)
                         identity = Secrets::MasterKey.read.identity
                         Secrets::Vault.decrypt(File.read(vault_path), identity)
                       elsif create
                         "# beryl credentials — créez vos sections [provider] ci-dessous.\n\n[ovh]\n# OVH_APPLICATION_KEY = \"\"\n"
                       else
                         STDERR.puts "beryl env edit : #{vault_path} n'existe pas. Passez `--create` pour le créer vide."
                         return 1
                       end

    plaintext_after = Secrets::Editor.edit(plaintext_before, suffix: ".toml")

    if plaintext_after == plaintext_before
      STDOUT.puts "[edit] aucune modification, coffre intact."
      return 0
    end

    # Validation TOML avant de chiffrer pour ne pas écrire un coffre cassé.
    begin
      ::TOML.parse(plaintext_after)
    rescue ex
      STDERR.puts "beryl env edit : le contenu édité n'est pas du TOML valide : #{ex.message}"
      STDERR.puts "                 le coffre n'a PAS été modifié."
      return 1
    end

    Dir.mkdir_p(account_dir)
    File.chmod(account_dir, 0o700)
    ciphertext = Secrets::Vault.encrypt(plaintext_after, Secrets::Recipients.encryption_keys)
    File.write(vault_path, ciphertext)
    File.chmod(vault_path, 0o600)

    STDOUT.puts "[edit] #{vault_path} mis à jour."
    # Coffre chiffré → commitable. Auto-commit dans le dépôt de config.
    Beryl::CLI::ConfigGit.commit(
      [vault_path],
      "env : coffre #{account} mis à jour (edit)",
      no_commit,
    )
    0
  rescue Secrets::NotInitializedError
    STDERR.puts "beryl env edit : aucune master key de chiffrement disponible."
    STDERR.puts "                 Lancez `secrets init` une première fois sur ce poste."
    1
  rescue ex
    STDERR.puts "beryl env edit : échec — #{ex.message}"
    1
  end

  # ─────────────────────────────────────────────────────────────
  # show
  # ─────────────────────────────────────────────────────────────

  private def self.cmd_show(config_root : String, argv : Array(String)) : Int32
    account = ""
    OptionParser.parse(argv.dup) do |parser|
      parser.banner = "USAGE : beryl env show <société>"
      parser.on("-h", "--help", "Affiche cette aide") { puts parser; exit 0 }
    end
    positional = argv.reject { |a| a.starts_with?("-") }
    account = positional.first if positional.size >= 1

    if account.empty?
      STDERR.puts "beryl env show : argument <société> manquant."
      return 64
    end

    vault_path = File.join(config_root, account, Beryl::Config::EnvFile::VAULT_FILENAME)
    unless File.exists?(vault_path)
      STDERR.puts "beryl env show : #{vault_path} n'existe pas."
      return 1
    end

    identity = Secrets::MasterKey.read.identity
    plaintext = Secrets::Vault.decrypt(File.read(vault_path), identity)
    STDERR.puts "─── #{vault_path} ───────────────────"
    STDOUT.puts plaintext
    STDERR.puts "─── fin du plaintext (à NE PAS commiter en clair) ───"
    0
  rescue Secrets::NotInitializedError
    STDERR.puts "beryl env show : aucune master key de chiffrement disponible."
    STDERR.puts "                 Lancez `secrets init` une première fois sur ce poste."
    1
  rescue ex
    STDERR.puts "beryl env show : échec — #{ex.message}"
    1
  end
end

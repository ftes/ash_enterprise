defmodule Mix.Tasks.AshEnterprise.Erasure.ErasePerson do
  @shortdoc "Erases a person by their address in one tenant, with a receipt (ADR 0024)"

  @moduledoc """
  Erases what one address reaches in one tenant (`AshEnterprise.Erasure.PersonErasure`):
  shreds the person's own erasure scopes, blanks their name and blind index, deletes
  their MDM statements, staged rows and derived joins, and writes a receipt.

      # What it would reach: counts only, writes nothing
      mix ash_enterprise.erasure.erase_person --tenant <organization uuid> \\
        --email person@example.com --as you@example.com --reason "erasure request"

      # Erase
      mix ash_enterprise.erasure.erase_person --tenant <organization uuid> \\
        --email person@example.com --as you@example.com --reason "erasure request" --apply

  * A dry run by default: it prints counts, never an address or a name, and whether
    `--as` may erase here. Nothing is written and no scope is opened.
  * `--apply` erases, as the person `--as` names, under their grants: they must hold
    `write` on `AshEnterprise.Erasure.PersonErasure` and on `AshEnterprise.Erasure.Scope`
    (operator-only), in the tenant their authority comes from. No system actor can
    erase. The address on the command line is the confirmation the action requires.
  * `--reason` is recorded on the receipt and in the audit trail, so it must not name
    the person.

  Irreversible. The receipt lists what it does not reach (backups, raw MDM landings,
  audit events written before the seal, a sign-in account's row); see
  `docs/runbooks/crypto-shredding.md`. Boots only the repo (iron law #23).
  """

  use Mix.Task

  alias AshEnterprise.Erasure
  alias AshEnterprise.Erasure.PersonErasure
  alias AshEnterprise.Erasure.PersonErasure.Subject
  alias AshEnterprise.Mix.Helpers
  alias AshEnterprise.Security.ActorContext

  @requirements ["app.config"]

  @switches [tenant: :string, email: :string, as: :string, reason: :string, apply: :boolean]

  @doc """
  The SOC 2 and privacy criteria this module records evidence for (erasure on request).

  Read by `AshCompliance.Ownership.Resolver.proves_producer/2`.
  """
  def evidence_controls, do: ["P4.3"]

  @impl Mix.Task
  def run(argv) do
    {opts, _args, _invalid} = OptionParser.parse(argv, strict: @switches)

    tenant = required!(opts, :tenant, "the organization whose person to erase")
    email = required!(opts, :email, "the address to erase")
    as = required!(opts, :as, "erasing a person is a person's decision")
    reason = required!(opts, :reason, "it is recorded on the receipt")

    tenant = uuid!(tenant)

    Helpers.boot_repo()
    Helpers.load_domain_resources()

    actor = operator!(as)

    if opts[:apply] do
      apply!(tenant, email, reason, actor, as)
    else
      dry_run(tenant, email, reason, actor, as)
    end
  end

  defp dry_run(tenant, email, reason, actor, as) do
    subject = Subject.find(tenant, email)

    allowed? =
      Ash.can?(
        {PersonErasure, :erase, %{email: email, confirm: email, reason: reason}},
        actor,
        tenant: tenant
      )

    Mix.shell().info(
      "Dry run: nothing written.\n" <>
        counts(Subject.counts(subject)) <>
        "\n  account: #{if subject.account?, do: "yes", else: "no"}" <>
        "\n#{as} #{if allowed?, do: "may", else: "may not"} erase in this tenant." <>
        "\nRun again with --apply to erase."
    )
  end

  defp apply!(tenant, email, reason, actor, as) do
    case Erasure.erase_person(email, email, reason, actor: actor, tenant: tenant) do
      {:ok, receipt} ->
        Mix.shell().info([
          :green,
          "Erased. Receipt #{receipt.id}, #{length(receipt.shredded_scope_ids)} scope(s) shredded.",
          :reset,
          "\n" <> counts(receipt.counts),
          "\nNot reached:\n" <> Enum.map_join(receipt.residuals, "\n", &("  - " <> &1))
        ])

      {:error, %Ash.Error.Forbidden{}} ->
        Mix.raise(
          "#{as} may not erase a person in this tenant (a write grant on person erasures " <>
            "and on erasure scopes, in their own tenant); nothing was changed."
        )

      {:error, error} ->
        Mix.raise("Erase refused, nothing was changed: #{Exception.message(error)}")
    end
  end

  defp counts(counts) do
    counts
    |> Enum.sort()
    |> Enum.map_join("\n", fn {key, value} -> "  #{key}: #{value}" end)
  end

  defp required!(opts, key, why) do
    case opts[key] do
      value when is_binary(value) and value != "" -> value
      _ -> Mix.raise("--#{key} is required: #{why}")
    end
  end

  defp uuid!(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> Mix.raise("--tenant must be an organization id (a UUID)")
    end
  end

  # The person is found with authorization off because a console has no actor until
  # one is resolved; the erase itself then runs as that person, under their grants.
  defp operator!(email) do
    case AshEnterprise.Accounts.get_user_by_email(email, authorize?: false) do
      {:ok, user} -> ActorContext.attach(user, ActorContext.build(user))
      {:error, _} -> Mix.raise("no user with email #{email}")
    end
  end
end

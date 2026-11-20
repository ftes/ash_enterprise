defmodule AshEnterpriseWeb.AcknowledgementLiveTest do
  @moduledoc """
  Acknowledgements (`/app/acknowledgements`, `AcknowledgementUI`) through the real
  LiveView, as the people it asks, and the route that serves the original bytes.

  Phrased first as what must not happen: another person's request listed or acted on, the
  bytes served to someone the request does not name or in another organization, an
  acknowledgement without consent. Then the person's own path: they see the request, open
  the documents, agree, acknowledge, and the second person's request is untouched.

  SYNTHETIC data only: every person is on `example.test` and every policy is a fixture.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, tenant!: 1, member!: 3]

  alias AshEnterprise.Compliance
  alias AshEnterprise.Signatures
  alias AshEnterprise.Signatures.Signer

  @moduletag evidence: true

  @policy "SYNTHETIC acceptable use policy, first version.\nBe kind to the machines."

  setup do
    admin = tenant!(operator?: true)

    %{
      admin: admin,
      ada: member!(admin, "Staff #{System.unique_integer([:positive])}", []),
      bo: member!(admin, "Staff #{System.unique_integer([:positive])}", []),
      policy: Compliance.publish_policy!("acceptable-use", "Acceptable use", @policy, opts(admin))
    }
  end

  describe "refused" do
    test "another person's request is neither listed nor actionable", ctx do
      ada_row = asked!(ctx, ctx.ada)
      bo_row = asked!(ctx, ctx.bo)

      {:ok, view, _html} = live(sign_in(build_conn(), ctx.bo.user), "/app/acknowledgements")
      listed = view |> pushed() |> rows("requests") |> Enum.map(& &1["id"])

      assert listed == [bo_row.id]
      refute ada_row.id in listed

      # Ada's row is not Bo's to open, agree to or acknowledge, by id, whatever the page
      # offered.
      for action <- ["view", "consent", "sign"] do
        messages = invoke(view, action, ada_row)
        assert %{"kind" => "error"} = feedback(messages)
      end

      assert %{status: :notified, viewed_at: nil, consented_at: nil, signed_at: nil} =
               reload(ada_row)
    end

    test "the administrator cannot acknowledge for a person", ctx do
      ada_row = asked!(ctx, ctx.ada)

      {:ok, view, _html} = live(sign_in(build_conn(), ctx.admin.user), "/app/acknowledgements")
      assert view |> pushed() |> rows("requests") == []
      assert %{"kind" => "error"} = feedback(invoke(view, "sign", ada_row))
      assert reload(ada_row).status == :notified
    end

    test "acknowledging without consent is refused, and nothing is recorded", ctx do
      row = asked!(ctx, ctx.ada)
      {:ok, view, _html} = live(sign_in(build_conn(), ctx.ada.user), "/app/acknowledgements")
      _ = pushed(view)

      # Not opened yet.
      assert %{"kind" => "error"} = feedback(invoke(view, "sign", row))
      assert reload(row).status == :notified

      # Opened, not agreed to.
      assert %{"kind" => "success"} = feedback(invoke(view, "view", row))
      assert %{"kind" => "error"} = feedback(invoke(view, "sign", row))
      assert %{status: :viewed, consented_at: nil, signed_at: nil} = reload(row)

      # And the package refuses it too, with the surface out of the way.
      assert {:error, _} =
               Signatures.sign_signature_request(reload(row),
                 actor: ctx.ada.actor,
                 tenant: ctx.ada.tenant
               )

      assert reload(row).signed_at == nil
    end

    test "the bytes are served only to a signer of a request that names the version", ctx do
      asked!(ctx, ctx.ada)
      path = "/app/acknowledgements/documents/#{ctx.policy.document_version_id}"

      # A signed-out visitor is sent to sign in.
      assert redirected_to(get(build_conn(), path)) =~ "/sign-in"

      # A person who is in the organization but not asked.
      assert get(sign_in(build_conn(), ctx.bo.user), path).status == 404
      # The administrator who sent it is not a signer either.
      assert get(sign_in(build_conn(), ctx.admin.user), path).status == 404

      # Someone in another organization.
      other = tenant!()
      assert get(sign_in(build_conn(), other.user), path).status == 404

      # An id nothing names, and one that is not an id.
      missing = "/app/acknowledgements/documents/#{Ash.UUID.generate()}"
      assert get(sign_in(build_conn(), ctx.ada.user), missing).status == 404

      assert get(sign_in(build_conn(), ctx.ada.user), "/app/acknowledgements/documents/nope").status ==
               404
    end

    test "a version the person's request does not name is not served to them", ctx do
      asked!(ctx, ctx.ada)

      other =
        Compliance.publish_policy!(
          "code-of-conduct",
          "Conduct",
          "SYNTHETIC other policy",
          opts(ctx.admin)
        )

      assert get(
               sign_in(build_conn(), ctx.ada.user),
               "/app/acknowledgements/documents/#{other.document_version_id}"
             ).status == 404
    end
  end

  describe "the person's own path" do
    test "they see the request, open the documents, agree and acknowledge; the other is untouched",
         ctx do
      ada_row = asked!(ctx, ctx.ada)
      bo_row = asked!(ctx, ctx.bo)

      {:ok, view, _html} = live(sign_in(build_conn(), ctx.ada.user), "/app/acknowledgements")
      [row] = view |> pushed() |> rows("requests")
      assert row["id"] == ada_row.id
      assert row["policies_label"] == "Acceptable use, version 1"

      # Before they open it, the documents are not shown.
      refute detail(ctx.ada, ada_row)["documents_shown"] =~ "Be kind to the machines"

      assert %{"kind" => "success"} = feedback(invoke(view, "view", ada_row))

      shown = detail(ctx.ada, ada_row)["documents_shown"]
      assert shown =~ "Acceptable use, version 1"
      assert shown =~ "Be kind to the machines"
      assert shown =~ ctx.policy.sha256
      assert shown =~ "/app/acknowledgements/documents/#{ctx.policy.document_version_id}"

      assert %{"kind" => "success"} = feedback(invoke(view, "consent", ada_row))
      assert %{"kind" => "success"} = feedback(invoke(view, "sign", ada_row))

      signed = reload(ada_row)
      assert signed.status == :signed
      assert signed.signed_at
      assert signed.shown_sha256

      # The same bytes the surface named are what the route serves them.
      conn =
        get(
          sign_in(build_conn(), ctx.ada.user),
          "/app/acknowledgements/documents/#{ctx.policy.document_version_id}"
        )

      assert response(conn, 200) == @policy
      assert hd(get_resp_header(conn, "content-type")) =~ "text/plain"

      # Bo's request is as it was.
      assert %{status: :notified, viewed_at: nil} = reload(bo_row)
    end

    test "declining takes a reason and ends the request", ctx do
      row = asked!(ctx, ctx.ada)
      {:ok, view, _html} = live(sign_in(build_conn(), ctx.ada.user), "/app/acknowledgements")
      _ = pushed(view)

      assert %{"kind" => "error"} = feedback(invoke(view, "decline", row, %{"reason" => ""}))
      assert reload(row).status == :notified

      assert %{"kind" => "success"} =
               feedback(invoke(view, "decline", row, %{"reason" => "SYNTHETIC: wrong team"}))

      assert reload(row).status == :declined
    end

    test "My tasks lists the request waiting on the person, linked to Acknowledgements", ctx do
      row = asked!(ctx, ctx.ada)
      bo = tenant_member_without_request(ctx)

      {:ok, view, _html} = live(sign_in(build_conn(), ctx.ada.user), "/app/tasks")
      assert [waiting] = view |> pushed() |> rows("acknowledgements")
      assert waiting["id"] == row.id

      assert %{"surface" => "acknowledgements", "recordId" => id} =
               waiting["_links"]["policies_label"]

      assert id == row.id

      {:ok, view, _html} = live(sign_in(build_conn(), bo.user), "/app/tasks")
      assert view |> pushed() |> rows("acknowledgements") == []
    end
  end

  describe "in French" do
    test "the buttons, the labels and the consent wording are French; English is unchanged",
         ctx do
      row = asked!(ctx, ctx.ada)
      surface = fn locale -> surface_text(ctx.ada, locale) end

      assert surface.("en") =~ "Acknowledge"
      refute surface.("en") =~ "Prendre acte"

      Gettext.put_locale(AshEnterpriseWeb.Locale.backend(), "fr")
      on_exit(fn -> Gettext.put_locale(AshEnterpriseWeb.Locale.backend(), "en") end)

      french = surface.("fr")
      assert french =~ "Prendre acte"
      assert french =~ "Ouvrir les documents"
      assert french =~ "J’accepte"
      assert french =~ "Refuser"
      refute french =~ "Acknowledge"

      wording = detail(ctx.ada, row)["consent_wording"]
      assert wording =~ "J’accepte"
      assert wording =~ "SHA-256"
      assert detail(ctx.ada, row)["documents_shown"] == "Ouvrez les documents pour les lire."
    end
  end

  # --- fixtures -----------------------------------------------------------------------

  defp opts(%{actor: actor, tenant: tenant}), do: [actor: actor, tenant: tenant]

  defp tenant_member_without_request(ctx),
    do: member!(ctx.admin, "Staff #{System.unique_integer([:positive])}", [])

  # One request over the policy, with the person as its one signer, sent.
  defp asked!(ctx, person) do
    request =
      Signatures.draft_signature_request!(
        %{
          subject_type: "synthetic_policy_set",
          subject_id: Ash.UUID.generate(),
          purpose: :acknowledge
        },
        opts(ctx.admin)
      )

    Signatures.add_signature_document!(
      %{request_id: request.id, source_version_id: ctx.policy.document_version_id, position: 1},
      opts(ctx.admin)
    )

    {:ok, signer} =
      Signatures.add_signer(
        %{request_id: request.id, role: :staff, order: 1, user_id: person.user.id},
        opts(ctx.admin)
      )

    Signatures.send_signature_request!(request, opts(ctx.admin))
    reload(signer)
  end

  defp reload(signer),
    do: Ash.get!(Signer, signer.id, authorize?: false, tenant: signer.organization_id)

  defp sign_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  defp pushed(view) do
    assert_push_event(view, "a2ui:messages", %{messages: messages}, 5_000)
    messages
  end

  defp invoke(view, action, signer, values \\ nil) do
    context = %{"action" => action, "recordId" => signer.id, "component" => "requests"}
    context = if values, do: Map.put(context, "values", values), else: context

    render_hook(
      view,
      "a2ui:message",
      AshEnterprise.A2uiMessage.ash_action("acknowledgements", "invoke", context,
        source: "acknowledgements"
      )
    )

    pushed(view)
  end

  # The rows of one table, from the bootstrap's data model or a refresh: a surface with one
  # table carries them as `/records` itself, one with several keyed by table name.
  defp rows(messages, table) do
    Enum.reduce(messages, [], fn
      %{"createSurface" => %{"dataModel" => %{"records" => records}}}, _acc ->
        table_rows(records, table)

      %{"updateDataModel" => %{"path" => "/records/" <> ^table, "value" => rows}}, _acc
      when is_list(rows) ->
        rows

      %{"updateDataModel" => %{"path" => "/records", "value" => records}}, _acc ->
        table_rows(records, table)

      _other, acc ->
        acc
    end)
  end

  defp table_rows(records, _table) when is_list(records), do: records
  defp table_rows(%{} = records, table), do: Map.get(records, table, [])

  defp feedback(messages) do
    Enum.find_value(messages, fn
      %{"updateDataModel" => %{"path" => "/ui/feedback", "value" => value}} -> value
      _other -> nil
    end)
  end

  # The surface as it is sent to the person: every string the page would show.
  defp surface_text(person, locale) do
    AshA2ui.Info.build_surface(AshEnterpriseWeb.A2ui.AcknowledgementUI,
      actor: person.actor,
      tenant: person.tenant,
      locale: locale,
      gettext_backend: {AshEnterpriseWeb.Gettext, "ash_a2ui"}
    )
    |> Jason.encode!()
  end

  # The detail the surface carries for the selected request, read as the person.
  defp detail(person, signer) do
    state =
      AshA2ui.Info.context_state_for(
        AshEnterpriseWeb.A2ui.AcknowledgementUI,
        %{"request" => signer.id},
        actor: person.actor,
        tenant: person.tenant
      )

    %{"updateDataModel" => %{"value" => value}} =
      AshA2ui.Info.build_data_model(AshEnterpriseWeb.A2ui.AcknowledgementUI,
        actor: person.actor,
        tenant: person.tenant,
        context_state: state
      )

    value["detail"]["request"]
  end
end

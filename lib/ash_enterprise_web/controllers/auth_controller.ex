defmodule AshEnterpriseWeb.AuthController do
  use AshEnterpriseWeb, :controller
  use AshAuthentication.Phoenix.Controller

  def success(conn, activity, user, _token) do
    # Signing in lands on the launcher (Today leads it), unless the visitor
    # was bounced to sign-in from somewhere else.
    return_to = get_session(conn, :return_to) || ~p"/app"

    message =
      case activity do
        {:confirm_new_user, :confirm} -> "Your email address has now been confirmed"
        {:password, :reset} -> "Your password has successfully been reset"
        _ -> "You are now signed in"
      end

    conn
    |> delete_session(:return_to)
    |> store_in_session(user)
    # If your resource has a different name, update the assign name here (i.e :current_admin)
    |> assign(:current_user, user)
    |> put_flash(:info, message)
    |> redirect(to: return_to)
  end

  def failure(conn, activity, reason) do
    record_protocol_refusal(activity, reason)

    message =
      case {activity, reason} do
        {_,
         %AshAuthentication.Errors.AuthenticationFailed{
           caused_by: %Ash.Error.Forbidden{
             errors: [%AshAuthentication.Errors.CannotConfirmUnconfirmedUser{}]
           }
         }} ->
          """
          You have already signed in another way, but have not confirmed your account.
          You can confirm your account using the link we sent to you, or by resetting your password.
          """

        {_,
         %AshAuthentication.Errors.AuthenticationFailed{
           caused_by: %AshAuthentication.Errors.ConfirmationRequired{}
         }} ->
          """
          An account with this email already exists. We've sent a link to that
          address - confirm it to finish linking this provider to your account.
          """

        # The identity provider's door (ADR 0071) names no password, and says no more
        # than that: not which of its rules refused, so it does not tell a caller whether
        # an address has an account here.
        {{:oidc, _phase}, _reason} ->
          gettext("This identity provider account is not linked to a confirmed account here.")

        _ ->
          "Incorrect email or password"
      end

    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/sign-in")
  end

  # `clear_session/2` revokes the stored session token before it clears the cookie, so a
  # page left open on it stops at its next event or navigation (`LiveUserAuth`).
  def sign_out(conn, _params) do
    return_to = get_session(conn, :return_to) || ~p"/"

    conn
    |> clear_session(:ash_enterprise)
    |> put_flash(:info, "You are now signed out")
    |> redirect(to: return_to)
  end

  # An OIDC attempt the protocol refused before the sign-in action ran (a forged or missing
  # state, a bad ID token or nonce, a refused code, a provider error or an unreachable
  # provider) is recorded at the oidc door here, by its class only (ADR 0071). A refusal by
  # the sign-in action arrives as `AuthenticationFailed` and was recorded by the action.
  defp record_protocol_refusal({:oidc, _phase}, %AshAuthentication.Errors.AuthenticationFailed{}),
    do: :ok

  defp record_protocol_refusal({:oidc, _phase}, reason),
    do: AshEnterprise.Security.AuthenticationAudit.oidc_protocol_refused(reason)

  defp record_protocol_refusal(_activity, _reason), do: :ok
end

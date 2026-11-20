defmodule AshEnterprise.Signatures.Actions.ReviewStatus do
  @moduledoc """
  Runs `AshEnterprise.Signatures.Request.review_status`: who has and has not acknowledged,
  for one policy review, read as the caller (`AshEnterprise.Signatures.ReviewStatus`).
  """

  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context) do
    AshEnterprise.Signatures.ReviewStatus.status(
      input.arguments.occurrence_id,
      Ash.Context.to_opts(context)
    )
  end
end

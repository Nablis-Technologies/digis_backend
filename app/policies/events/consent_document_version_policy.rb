# frozen_string_literal: true

module Events
  class ConsentDocumentVersionPolicy < Core::ApplicationPolicy
    def show? = true

    class Scope < Core::ApplicationPolicy::Scope
      def resolve = scope.all
    end
  end
end

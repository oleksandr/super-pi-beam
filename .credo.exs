%{
  configs: [
    %{
      name: "default",
      checks: [
        {Credo.Check.Design.DuplicatedCode, []},
        {Credo.Check.Warning.UnsafeExec, false}
      ]
    }
  ]
}

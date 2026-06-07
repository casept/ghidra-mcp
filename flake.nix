{
  description = "ghidra-mcp — MCP server bridging Ghidra with AI tools (build + bridge runtime deps)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # Java toolchain for the Ghidra extension (Java 21 LTS, Ghidra 12.1).
        jdk = pkgs.jdk21;

        # Python interpreter + runtime deps for bridge_mcp_ghidra.py.
        # The bridge itself only needs `mcp` and `requests`; the rest mirror
        # requirements-test.txt so the test suite is runnable from the shell.
        pythonEnv = pkgs.python3.withPackages (ps: [
          # Runtime (requirements.txt)
          ps.mcp
          ps.requests
          # Tests (requirements-test.txt)
          ps.pytest
          ps.pytest-cov
          ps.pytest-xdist
          ps.pytest-timeout
          ps.pytest-mock
          ps.pytest-asyncio
          ps.responses
          ps.requests-mock
          ps.coverage
          ps.pytest-json-report
          ps.pyyaml
        ]);

        buildTools = [
          jdk
          pkgs.maven
          pkgs.gradle
        ];
      in
      {
        devShells.default = pkgs.mkShell {
          packages = buildTools ++ [ pythonEnv ];

          JAVA_HOME = "${jdk}";
        };

        packages.pythonEnv = pythonEnv;
      });
}

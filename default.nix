{ mkDerivation, base, bytestring, pipes, pipes-group, pipes-parse
, stdenv, transformers
}:
mkDerivation {
  pname = "pipes-bytestring";
  version = "2.1.5";
  src = ./.;
  libraryHaskellDepends = [
    base bytestring pipes pipes-group pipes-parse transformers
  ];
  description = "ByteString support for pipes";
  license = stdenv.lib.licenses.bsd3;
}

{ mkDerivation, base, bytestring, pipes, pipes-group, pipes-parse
, stdenv, stringsearch, transformers
}:
mkDerivation {
  pname = "pipes-bytestring";
  version = "2.1.6";
  src = ./.;
  libraryHaskellDepends = [
    base bytestring pipes pipes-group pipes-parse stringsearch
    transformers
  ];
  description = "ByteString support for pipes";
  license = stdenv.lib.licenses.bsd3;
}

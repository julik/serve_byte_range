D = Steep::Diagnostic

target :lib do
  signature "sig"
  # Kept out of sig/ so that it does not ship with the gem and clash with Rack signatures apps may have
  signature "sig_shims"
  check "lib"
  library "digest"
  configure_code_diagnostics(D::Ruby.default)
end

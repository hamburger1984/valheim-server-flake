{
  lib,
  stdenv,
  fetchSteam,
}:
stdenv.mkDerivation (finalAttrs: {
  name = "valheim-server";
  version = "0.220.5";
  src = fetchSteam {
    inherit (finalAttrs) name;
    appId = "896660";
    depotId = "896661";
    manifestId = "18007466826975597";
    hash = "sha256-8UdoLzKiu8CEztqwTHGP5M3RdrrVUTmAwN6Cqt9R+v8=";
  };

  # Skip phases that don't apply to prebuilt binaries.
  dontBuild = true;
  dontConfigure = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    cp -r \
      *.so \
      *.debug \
      valheim_server.x86_64 \
      valheim_server_Data \
      $out

    chmod +x $out/valheim_server.x86_64

    runHook postInstall
  '';

  meta = with lib; {
    description = "Valheim dedicated server";
    homepage = "https://steamdb.info/app/896660/";
    changelog = "https://store.steampowered.com/news/app/892970?updates=true";
    sourceProvenance = with sourceTypes; [binaryBytecode binaryNativeCode];
    license = licenses.unfree;
    maintainers = with maintainers; [aidalgol];
    platforms = ["x86_64-linux"];
  };
})

# TensorFlow Lite Swift wrapper

Nine Swift source files are copied without modification from
https://github.com/readdle/tensorflow-lite-swift at tag 2.16.1,
commit 3752f2ec00a04c13ece05fb420d2575178b321b9.
Each retains Google's copyright and Apache 2.0 license header.
The accompanying LICENSE is the standard Apache 2.0 license text.

The local package manifest keeps the TensorFlowLite product/module and the
original TensorFlowLiteC binary URL. It pins the verified archive checksum
instead of the nonmatching checksum in the remote manifest. It omits the
upstream test target and Android-only linker setting because this integration
is for Apple platforms. PROVENANCE.json records individual source hashes and
the binary archive pin. No framework bytes are patched or vendored here.

The binary is still downloaded and checksum-verified by Xcode/SwiftPM.
The provenance checks establish the reviewed publisher asset and source
revision; they do not establish a reproducible build or native compatibility.

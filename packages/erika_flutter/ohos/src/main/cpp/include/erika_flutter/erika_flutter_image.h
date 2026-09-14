#ifndef ERIKA_FLUTTER_IMAGE_H_
#define ERIKA_FLUTTER_IMAGE_H_

#include <napi/native_api.h>

// Registers the static-image N-API surface on the Flutter plugin module.
// Image work owns no ErikaPlayer/Presenter and never starts playback, audio,
// timeline polling, or DisplaySoloist frame driving.
napi_status ErikaFlutterDefineImageExports(napi_env env, napi_value exports);

#endif

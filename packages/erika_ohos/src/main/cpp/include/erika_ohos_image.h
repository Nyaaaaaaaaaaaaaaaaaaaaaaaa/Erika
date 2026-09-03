#ifndef ERIKA_OHOS_IMAGE_H_
#define ERIKA_OHOS_IMAGE_H_

#include <napi/native_api.h>

// Adds the decode-once static-image N-API surface to the OHPM module. The
// implementation owns no ErikaPlayer/Presenter and never starts playback,
// timeline, event polling, VSync, or audio work.
napi_status ErikaOhosDefineImageExports(napi_env env, napi_value exports);

#endif

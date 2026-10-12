/*
 * Copyright 2006 The Android Open Source Project
 *
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 */

#include "include/private/base/SkDebug.h"
#include "include/private/base/SkFeatures.h"
#include "include/private/base/SkLoadUserConfig.h"

#if !defined(SK_BUILD_FOR_WIN) && !defined(SK_BUILD_FOR_ANDROID)

#include <stdarg.h>
#include <stdio.h>

void SkDebugf(const char format[], ...) {
    (void)format;  // QIP: no host stderr or logging imports.
}
#endif  // !defined(SK_BUILD_FOR_WIN) && !defined(SK_BUILD_FOR_ANDROID)

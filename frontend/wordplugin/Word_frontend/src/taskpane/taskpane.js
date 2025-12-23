/*
 * Copyright (c) Microsoft Corporation. All rights reserved. Licensed under the MIT license.
 * See LICENSE in the project root for license information.
 */

/* global document, Office, Word */

Office.onReady((info) => {
  if (info.host === Office.HostType.Word) {
    console.log("Office is ready in Word (Flutter Wrapper)");
  }
});

export async function run() {
  // Placeholder
}

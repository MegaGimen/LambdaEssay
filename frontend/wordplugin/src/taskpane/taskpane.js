/*
 * Copyright (c) Microsoft Corporation. All rights reserved. Licensed under the MIT license.
 * See LICENSE in the project root for license information.
 */

/* global Office */

Office.onReady((info) => {
  if (info.host === Office.HostType.Word) {
    // The taskpane is ready.
    // The content is handled by the iframe in taskpane.html.
    console.log("Office Add-in ready. Hosting localhost:3891 in iframe.");
  }
});

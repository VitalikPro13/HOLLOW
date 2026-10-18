#!/bin/sh
# Puts the build variant's Firebase config into the app bundle. Production
# (HOLLOW_FIREBASE_PLIST empty) keeps the file Copy Bundle Resources placed. A
# variant whose own config is missing ships none, so it can never register a
# push token under the production Firebase app.
set -e
[ -z "${HOLLOW_FIREBASE_PLIST}" ] && exit 0
dst="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/GoogleService-Info.plist"
src="${PROJECT_DIR}/${HOLLOW_FIREBASE_PLIST}"
if [ ! -f "${src}" ]; then
  rm -f "${dst}"
  echo "warning: ios/${HOLLOW_FIREBASE_PLIST} is missing, so ${PRODUCT_BUNDLE_IDENTIFIER} builds without push."
  exit 0
fi
id=$(/usr/libexec/PlistBuddy -c "Print :BUNDLE_ID" "${src}")
if [ "${id}" != "${PRODUCT_BUNDLE_IDENTIFIER}" ]; then
  echo "error: ios/${HOLLOW_FIREBASE_PLIST} belongs to ${id}, not ${PRODUCT_BUNDLE_IDENTIFIER}."
  exit 1
fi
cp "${src}" "${dst}"

import 'package:hollow/src/rust/api/storage.dart' as storage_api;

/// The Terms of Use revision a person agrees to, named by the date of the
/// change. Bump it only for a change everyone must agree to again: every
/// profile that agreed to an older one is asked once more.
const kTermsVersion = '2026-10-19';

/// Per profile: the setting lives in that profile's own database.
const kTermsAgreedKey = 'terms_agreed_version';

/// Whether this profile still has to agree to [kTermsVersion]. A store that
/// cannot be read counts as due, so the question is asked, never skipped.
Future<bool> termsAgreementDue() async {
  try {
    return await storage_api.loadSetting(key: kTermsAgreedKey) != kTermsVersion;
  } catch (_) {
    return true;
  }
}

Future<void> recordTermsAgreement() =>
    storage_api.saveSetting(key: kTermsAgreedKey, value: kTermsVersion);

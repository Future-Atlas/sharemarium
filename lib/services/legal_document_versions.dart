class LegalDocumentVersions {
  const LegalDocumentVersions._();

  // Each legal document uses an independent MAJOR.MINOR.PATCH version.
  // PATCH: changes that do not alter meaning, rights, or obligations.
  // MINOR: substantive but non-fundamental changes.
  // MAJOR: fundamental or incompatible changes to terms or systems.
  // Increasing MAJOR resets MINOR/PATCH to zero; increasing MINOR resets PATCH.
  // Full rules and revision reasons: docs/legal_changelog.md

  // Technical consent-set identifier. This is not a document version.
  static const bundle = '1.10.0';

  static const terms = '1.9.0';
  static const privacy = '1.8.0';
  static const communityGuidelines = '1.3.0';
  static const infringementPolicy = '1.2.0';
  static const externalTransmission = '1.8.0';
}

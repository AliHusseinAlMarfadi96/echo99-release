/// Firestore document ids must never be an email or contain a dot.
bool isSafeDocId(String id) {
  if (id.isEmpty || id.length > 200) {
    return false;
  }
  return !id.contains('.') && !id.contains('/') && !id.contains('@');
}

String requireDocId(String id) {
  if (!isSafeDocId(id)) {
    throw ArgumentError(
      'Refusing a Firestore id that is empty, an email, or contains "."',
    );
  }
  return id;
}

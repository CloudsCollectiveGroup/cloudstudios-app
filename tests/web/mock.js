// Ersetzt supabase-js im Test: RPC geht an den lokalen Testserver, Anmeldung über ?user=<uuid>
window.supabase = { createClient() {
  const uid = new URLSearchParams(location.search).get('user');
  const ses = uid ? { user: { id: uid } } : null;
  return {
    rpc: async (name, args) => (await fetch('/rpc/' + name, { method: 'POST', headers: { 'X-User': uid }, body: JSON.stringify(args || {}) })).json(),
    auth: { getSession: async () => ({ data: { session: ses } }), signInWithPassword: async () => ({ error: { message: 'invalid' } }),
      signOut: async () => ({}), onAuthStateChange() {}, updateUser: async () => ({}) },
    storage: { from: () => ({ upload: async () => ({ error: null }) }) },
    functions: { invoke: async () => ({ data: null, error: { message: 'nicht im Test' } }) }
  };
} };

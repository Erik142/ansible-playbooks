// n8n external hook: trust an identity header set by the reverse proxy and issue
// n8n's own session cookie, so the editor needs no second (native) login.
//
// Loaded via EXTERNAL_HOOK_FILES. Only safe behind a proxy that (a) strips any
// client-supplied copy of the header and (b) sets it from an authenticated session.
// See roles/n8n/README.md ("Trusted-header login") and roles/n8n/templates/n8n.container.j2.
//
// Depends on n8n internals (cookie-parser layer name, AuthService.issueJWT/issueCookie,
// the n8n-auth cookie name). Check them by hand per image when bumping n8n_image.

const path = require('node:path');

const N8N = '/usr/local/lib/node_modules/n8n';
const { Container } = require(path.join(N8N, 'node_modules/@n8n/di'));
const { UserRepository } = require(path.join(N8N, 'node_modules/@n8n/db'));
const { AuthService } = require(path.join(N8N, 'dist/auth/auth.service.js'));
const { AUTH_COOKIE_NAME } = require(path.join(N8N, 'dist/constants.js'));

const HEADER = (process.env.N8N_TRUSTED_EMAIL_HEADER || 'x-auth-request-email').toLowerCase();
const TAG = '[trusted-email-hook]';
// Never look at these: health, assets and the webhook routes authenticate on their own.
const SKIP = /^\/(webhook|webhook-test|healthz|assets|static)(\/|$)/;

module.exports = {
  n8n: {
    ready: [
      async function (server) {
        const app = server.app;
        const router = app.router || app._router;
        const stack = router.stack;

        // Our middleware must run after cookie-parser (so req.cookies exists) and before the
        // routes. Refuse to register if that position cannot be found: then n8n's own login
        // stays in place, which is the safe fallback.
        const cookieIdx = stack.findIndex((layer) => layer.name === 'cookieParser');
        if (cookieIdx < 0) {
          console.error(`${TAG} disabled: cookieParser layer not found`);
          return;
        }

        app.use(async (req, res, next) => {
          try {
            if (req.cookies && req.cookies[AUTH_COOKIE_NAME]) return next();
            if (SKIP.test(req.path)) return next();
            const email = req.headers[HEADER];
            if (!email) return next();

            const user = await Container.get(UserRepository).findOne({
              where: { email: String(email) },
              relations: ['role'],
            });
            if (!user) return res.status(401).json({ message: 'unknown user' });

            const auth = Container.get(AuthService);
            const token = auth.issueJWT(user, false, undefined, false);
            req.cookies = { ...(req.cookies || {}), [AUTH_COOKIE_NAME]: token };
            auth.issueCookie(res, user);
            return next();
          } catch (error) {
            return next(error);
          }
        });

        // app.use() appended the new layer last. Move it to just after cookie-parser.
        const layer = stack.pop();
        stack.splice(cookieIdx + 1, 0, layer);
        console.log(`${TAG} active; header=${HEADER}`);
      },
    ],
  },
};

# container

Generic helper role that renders a single Podman **Quadlet** (`.container`)
template to the target and restarts its systemd service — but only when the
rendered unit actually changes (idempotent).

You normally don't list this role in `site.yml`. Instead, a *service* role
includes it once per container.

## Role variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `container_name` | yes | – | Service/unit base name; deployed as `<name>.container`. |
| `container_quadlet_src` | yes | – | **Filename** of the `.container` Quadlet **template** (`.j2`), looked up in the calling role's `templates/` dir and rendered with that role's vars. |
| `container_quadlet_dir` | no | `/etc/containers/systemd` | Target Quadlet directory. |

## Adding a new service (the pattern)

1. Create a service role, e.g. `roles/mealie/`.
2. Put the Quadlet **template** at `roles/mealie/templates/mealie.container.j2`
   — it's rendered with your role's variables (image tag, env, volumes, …).
3. In `roles/mealie/tasks/main.yml`, deploy any config/data first, then call
   this helper:

   ```yaml
   - name: Create the Mealie data directory
     ansible.builtin.file:
       path: "{{ mealie_data_dir }}"
       state: directory
       owner: root
       group: root
       mode: "0750"

   - name: Deploy the Mealie container
     ansible.builtin.include_role:
       name: container
     vars:
       container_name: mealie
       container_quadlet_src: mealie.container.j2
   ```

   Pass just the template's **filename** — this role resolves it against your
   service role's `templates/` dir (via `ansible_parent_role_paths`). Don't pass
   a `{{ role_path }}`-based path: `include_role` vars are templated lazily, so
   `role_path` would resolve to the `container` role, not yours.

4. Add `- role: mealie` to `site.yml`.

## Why `flush_handlers` instead of a plain handler?

The restart is a notified handler that is **flushed inside the include**. If it
ran at end-of-play like a normal handler, `{{ container_name }}` would resolve to
whichever service was included last and restart the wrong unit. Flushing
per-include keeps the variable in scope and starts services in order.

import cf from "cloudfront";

const routes = cf.kvs();

async function handler(event) {
  const request = event.request;

  try {
    const target = await routes.get(request.uri);
    if (target) {
      request.uri = target;
      return request;
    }
  } catch (error) {
    // Continue to project-folder routing.
  }

  const segments = request.uri.split("/").filter(Boolean);
  if (segments.length > 0) {
    try {
      const projectValue = await routes.get(`project:${segments[0]}`);
      const project = JSON.parse(projectValue);
      const relativePath = segments.slice(1).join("/") || project.entry;
      request.uri = `${project.prefix}/${relativePath}`;
    } catch (error) {
      // Unregistered paths continue to the portfolio origin unchanged.
    }
  }

  return request;
}

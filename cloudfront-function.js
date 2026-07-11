import cf from "cloudfront";

const routes = cf.kvs();

async function handler(event) {
  const request = event.request;

  try {
    const target = await routes.get(request.uri);
    if (target) {
      request.uri = target;
    }
  } catch (error) {
    // Unregistered paths continue to the portfolio origin unchanged.
  }

  return request;
}

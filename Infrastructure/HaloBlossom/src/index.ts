import { handleBlossomRequest } from "./blossom";

export { handleBlossomRequest } from "./blossom";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      return await handleBlossomRequest(request, env);
    } catch (error) {
      const url = new URL(request.url);
      console.error(
        JSON.stringify({
          message: "Unhandled Blossom request error",
          method: request.method,
          path: url.pathname,
          error: error instanceof Error ? error.message : "Unknown error",
        }),
      );
      return Response.json(
        { error: "The Blossom server could not complete this request." },
        {
          status: 500,
          headers: {
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-store",
            "X-Reason": "The Blossom server could not complete this request.",
          },
        },
      );
    }
  },
} satisfies ExportedHandler<Env>;

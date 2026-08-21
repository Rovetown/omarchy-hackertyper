<?php
// SPDX-License-Identifier: MIT
// :: This purpose-written source provides the PHP typing sequence bundled with Hacker Typer.
// :: Hacker Typer loads it as plain text and never evaluates or executes it.
// API request router with route matching, quota buckets, and response envelopes.

declare(strict_types=1);

final class ApiRequest
{
    public function __construct(
        public readonly string $method,
        public readonly string $path,
        public readonly array $headers = [],
        public readonly array $query = [],
        public readonly array $body = [],
        public readonly string $requestId = 'orchestrator-request'
    ) {}

    public function header(string $name): ?string
    {
        foreach ($this->headers as $key => $value) {
            if (strtolower((string) $key) === strtolower($name)) return (string) $value;
        }
        return null;
    }
}

final class ApiResponse
{
    public function __construct(
        public readonly int $status,
        public readonly array $headers,
        public readonly array $payload
    ) {}

    public static function json(int $status, array $payload, array $headers = []): self
    {
        return new self($status, array_merge(['content-type' => 'application/json'], $headers), $payload);
    }
}

final class MemoryCache
{
    /** @var array<string, array{value: array, expires: int, tags: string[]}> */
    private array $items = [];

    public function get(string $key, int $now): ?array
    {
        $item = $this->items[$key] ?? null;
        if ($item === null || $item['expires'] <= $now) { unset($this->items[$key]); return null; }
        return $item['value'];
    }

    public function put(string $key, array $value, int $ttl, int $now, array $tags = []): void
    {
        $this->items[$key] = ['value' => $value, 'expires' => $now + max(1, $ttl), 'tags' => $tags];
    }

    public function forgetTag(string $tag): int
    {
        $removed = 0;
        foreach ($this->items as $key => $item) {
            if (in_array($tag, $item['tags'], true)) { unset($this->items[$key]); $removed++; }
        }
        return $removed;
    }
}

final class SlidingWindowLimiter
{
    /** @var array<string, list<int>> */
    private array $hits = [];

    public function check(string $key, int $now, int $limit = 20, int $window = 60): array
    {
        $cutoff = $now - $window;
        $recent = array_values(array_filter($this->hits[$key] ?? [], static fn (int $stamp): bool => $stamp > $cutoff));
        $allowed = count($recent) < $limit;
        if ($allowed) $recent[] = $now;
        $this->hits[$key] = $recent;
        return ['allowed' => $allowed, 'remaining' => max(0, $limit - count($recent)), 'reset' => $now + $window];
    }
}

final class RouteMatch
{
    public function __construct(public readonly string $name, public readonly array $params = []) {}
}

final class RouteTable
{
    /** @var list<array{method: string, pattern: string, name: string, handler: callable}> */
    private array $routes = [];

    public function add(string $method, string $pattern, string $name, callable $handler): void
    {
        $this->routes[] = compact('method', 'pattern', 'name', 'handler');
    }

    public function match(ApiRequest $request): ?array
    {
        foreach ($this->routes as $route) {
            if ($route['method'] !== strtoupper($request->method)) continue;
            $names = [];
            $regex = preg_replace_callback('/\{([a-zA-Z][a-zA-Z0-9_]*)\}/', static function (array $m) use (&$names): string {
                $names[] = $m[1];
                return '([^/]+)';
            }, $route['pattern']);
            if ($regex !== null && preg_match('#^' . $regex . '$#', $request->path, $matches)) {
                array_shift($matches);
                return [$route, new RouteMatch($route['name'], array_combine($names, $matches) ?: [])];
            }
        }
        return null;
    }
}

final class RequestRouter
{
    private RouteTable $routes;
    private MemoryCache $cache;
    private SlidingWindowLimiter $limiter;
    private array $audit = [];

    public function __construct()
    {
        $this->routes = new RouteTable();
        $this->cache = new MemoryCache();
        $this->limiter = new SlidingWindowLimiter();
        $this->defineRoutes();
    }

    public function dispatch(ApiRequest $request, int $now = 1_700_000_000): ApiResponse
    {
        $requestId = $request->requestId;
        $clientKey = $request->header('x-orchestrator-client') ?? 'anonymous';
        $quota = $this->limiter->check($clientKey, $now);
        $quotaHeaders = ['x-rate-remaining' => (string) $quota['remaining'], 'x-rate-reset' => (string) $quota['reset'], 'x-request-id' => $requestId];
        $this->audit[] = ['id' => $requestId, 'method' => $request->method, 'path' => $request->path, 'at' => $now];
        if (!$quota['allowed']) return ApiResponse::json(429, ['error' => 'orchestrator quota exceeded', 'requestId' => $requestId], $quotaHeaders);
        if (!in_array(strtoupper($request->method), ['GET', 'POST', 'PATCH'], true)) return ApiResponse::json(405, ['error' => 'method not available in sample'], $quotaHeaders);
        $matched = $this->routes->match($request);
        if ($matched === null) return ApiResponse::json(404, ['error' => 'service route not found', 'path' => $request->path], $quotaHeaders);
        [$route, $match] = $matched;
        try {
            $response = ($route['handler'])($request, $match);
            return new ApiResponse($response->status, array_merge($quotaHeaders, $response->headers), $response->payload);
        } catch (InvalidArgumentException $error) {
            return ApiResponse::json(400, ['error' => $error->getMessage(), 'requestId' => $requestId], $quotaHeaders);
        }
    }

    public function auditTrail(): array { return array_slice($this->audit, -20); }

    private function defineRoutes(): void
    {
        $this->routes->add('GET', '/orchestrator/cards/{cardId}', 'card.show', function (ApiRequest $request, RouteMatch $match): ApiResponse {
            $cardId = $match->params['cardId'] ?? '';
            if (!preg_match('/^[a-z0-9-]{3,32}$/', $cardId)) throw new InvalidArgumentException('invalid service card id');
            $cacheKey = 'card:' . $cardId;
            $now = 1_700_000_000;
            $cached = $this->cache->get($cacheKey, $now);
            if ($cached !== null) return ApiResponse::json(200, $cached, ['x-cache' => 'HIT', 'cache-control' => 'max-age=30']);
            $payload = ['data' => ['id' => $cardId, 'title' => 'orchestrator card ' . $cardId, 'labels' => ['sample', 'service']], 'meta' => ['source' => 'memory']];
            $this->cache->put($cacheKey, $payload, 30, $now, ['cards']);
            return ApiResponse::json(200, $payload, ['x-cache' => 'MISS', 'cache-control' => 'max-age=30']);
        });

        $this->routes->add('POST', '/orchestrator/cards', 'card.create', function (ApiRequest $request): ApiResponse {
            $title = trim((string) ($request->body['title'] ?? ''));
            if ($title === '' || strlen($title) > 80) throw new InvalidArgumentException('title must be between 1 and 80 characters');
            $labels = array_values(array_filter((array) ($request->body['labels'] ?? []), static fn ($label): bool => is_string($label) && strlen($label) < 24));
            return ApiResponse::json(202, ['data' => ['id' => 'pending-orchestrator-card', 'title' => $title, 'labels' => $labels], 'meta' => ['queued' => true]], ['location' => '/orchestrator/cards/pending-orchestrator-card']);
        });

        $this->routes->add('PATCH', '/orchestrator/cards/{cardId}', 'card.update', function (ApiRequest $request, RouteMatch $match): ApiResponse {
            $cardId = $match->params['cardId'] ?? 'unknown';
            $changes = array_intersect_key($request->body, array_flip(['title', 'labels', 'color']));
            if ($changes === []) throw new InvalidArgumentException('no supported changes supplied');
            $this->cache->forgetTag('cards');
            return ApiResponse::json(200, ['data' => ['id' => $cardId, 'changes' => $changes], 'meta' => ['cache' => 'invalidated']]);
        });
    }
}

$router = new RequestRouter();
$request = new ApiRequest('GET', '/orchestrator/cards/alpha-01', ['x-orchestrator-client' => 'terminal-visitor'], [], [], 'req-001');
$response = $router->dispatch($request);
// Response envelope is available to the caller for structured logging.

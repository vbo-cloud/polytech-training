---
name: dotnet-conventions
description: Conventions expertes pour tout code C#/.NET dans ce projet (worker, future API "Polls"). Utilise cette skill dès qu'il s'agit d'écrire, modifier ou revoir du C# — accès base de données (EF Core), configuration, logging, gestion d'erreurs, ou tests. Sers-t'en aussi pour repérer les écarts entre le code existant (worker/Program.cs) et ces conventions, et explique pourquoi la convention est préférable.
---

# Conventions .NET / C# — projet polytech-training

Ce fichier sert deux usages : guider **Claude Code** quand il écrit du C# (notamment EF Core pour le worker), et donner à **Claude Cowork** une base pour signaler les écarts et les expliquer.

Le worker actuel (`worker/Program.cs`) enfreint plusieurs de ces conventions volontairement — c'est le code de départ fourni par Avisto, pas un modèle à copier. Le but du Sprint 2 (`SUIVI.md`) est justement de le faire converger vers ces pratiques.

## Configuration

**Ne jamais lire les variables d'environnement directement dans le code métier** (`Environment.GetEnvironmentVariable("X")` éparpillé). C'est ce que fait le worker actuel — ça fonctionne, mais ça rend la config impossible à valider au démarrage, difficile à tester, et invisible dans l'IDE.

Préférer le pattern `IOptions<T>` :
```csharp
public class DatabaseOptions
{
    public string ConnectionString { get; set; } = string.Empty;
}

// Program.cs
builder.Services.Configure<DatabaseOptions>(builder.Configuration.GetSection("Database"));

// Ailleurs, injecté :
public class MyService(IOptions<DatabaseOptions> options)
{
    private readonly string _connectionString = options.Value.ConnectionString;
}
```
Pourquoi : la config devient testable, typée, et centralisée — un seul endroit à regarder pour savoir ce que l'appli attend, plutôt que de grep le code entier.

## Logging

**Jamais `Console.WriteLine`/`Console.Error.WriteLine` dans du code de production** (encore une fois, ce que fait le worker actuel). Utiliser `ILogger<T>` (Microsoft.Extensions.Logging), injecté par constructeur :
```csharp
public class VoteProcessor(ILogger<VoteProcessor> logger)
{
    public void Process(Vote vote)
    {
        logger.LogInformation("Processing vote for {Option}", vote.Option);
    }
}
```
Pourquoi : `ILogger` permet de filtrer par niveau (Debug/Info/Warning/Error), de router vers plusieurs destinations (console, fichier, Application Insights — cf. décision de scope monitoring), et d'utiliser le "structured logging" (`{Option}` devient un champ recherchable, pas juste du texte concaténé).

## Accès aux données (EF Core)

- **DbContext à durée de vie courte** : un `DbContext` par opération/requête, jamais un singleton partagé — il n'est pas thread-safe.
- **Toujours async** : `ToListAsync()`, `SaveChangesAsync()`, `FirstOrDefaultAsync()` — jamais leurs équivalents synchrones dans du code qui tourne dans un contexte async (bloque un thread pour rien).
- **Migrations, pas `EnsureCreated()`** : `EnsureCreated()` est pratique pour un prototype, mais ne gère pas l'évolution du schéma. Utiliser `dotnet ef migrations add` + `dotnet ef database update`, pour avoir un historique versionné du schéma (cohérent avec l'approche Git du projet).
- **Attention aux N+1** : charger les relations avec `.Include()` explicitement, sinon chaque accès à une propriété de navigation déclenche une requête séparée.
- **Séparer le modèle EF Core du DTO exposé** (si une API voit le jour, cf. backlog "Polls") : ne jamais retourner une entité EF Core directement depuis un endpoint — fuite d'implémentation, risque de sur-exposition de données.

## Async / Threading

- **Async de bout en bout** : dès qu'une méthode appelle du code async, elle doit elle-même être async et propager avec `await`. Ne jamais faire `.Result` ou `.Wait()` sur une `Task` — ça peut provoquer un deadlock, en particulier dans un contexte avec `SynchronizationContext`.
- Le worker actuel utilise `Thread.Sleep()` dans une boucle synchrone pour temporiser — à remplacer par `await Task.Delay()` en async, ou mieux, par Polly (voir ci-dessous).

## Résilience (Polly)

Remplacer les boucles de retry manuelles (`while(true) { try {...} catch {...} Thread.Sleep(1000); } }`, présentes dans `Program.cs` pour la connexion DB et Redis) par une politique Polly explicite :
```csharp
var retryPolicy = Policy
    .Handle<NpgsqlException>()
    .WaitAndRetryAsync(5, attempt => TimeSpan.FromSeconds(Math.Pow(2, attempt)));

await retryPolicy.ExecuteAsync(async () => await connection.OpenAsync());
```
Pourquoi : la politique est déclarative, testable isolément, et le backoff exponentiel évite de marteler une base de données qui redémarre (on l'a observé en local — Postgres met quelques secondes à être prêt).

## Nommage

- `PascalCase` pour les membres publics (classes, méthodes, propriétés)
- `camelCase` pour les variables locales et paramètres
- Interfaces préfixées par `I` (`IVoteRepository`, pas `VoteRepository` pour l'interface)
- Noms de méthodes async suffixés par `Async` (`GetVotesAsync`, pas `GetVotes` si elle retourne une `Task`)

## Gestion d'erreurs

- Ne jamais attraper `Exception` de façon générique pour l'ignorer silencieusement. Attraper des types spécifiques (`NpgsqlException`, `SocketException`) quand on sait comment réagir.
- Si une exception est vraiment inattendue, la laisser remonter plutôt que de l'avaler — un crash visible vaut mieux qu'un état incohérent silencieux.

## Tests

- xUnit est le framework le plus courant dans l'écosystème .NET moderne (alternative : NUnit).
- Structure Arrange-Act-Assert, un scénario par test, noms de tests descriptifs (`MethodName_Scenario_ExpectedResult`).

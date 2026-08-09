using System;
using System.Data.Common;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;
using Newtonsoft.Json;
using Npgsql;
using StackExchange.Redis;

namespace Worker
{
    public class Program
    {
        private static readonly CancellationTokenSource cts = new CancellationTokenSource();

        public static async Task Main(string[] args)
        {
            try
            {
                // Le serveur de santé démarre avant l'ouverture des connexions,
                // pas après : `OpenDbConnection` et `OpenRedisConnection` bouclent
                // indéfiniment tant que leur cible ne répond pas. Démarré ensuite,
                // le port 8080 n'était jamais lié pendant qu'une dépendance était
                // indisponible — un orchestrateur qui sonde ce port en conclut que
                // le conteneur ne démarre pas et le recycle en boucle. Le worker se
                // déclare vivant, pas prêt : c'est la distinction qui manque encore
                // ici, à traiter au Sprint 2.
                Task.Run(() => StartHealthCheckServer(cts.Token));

                var pgsql = OpenDbConnection();
                var redisConn = OpenRedisConnection();
                var redis = redisConn.GetDatabase();

                // Keep alive is not implemented in Npgsql yet. This workaround was recommended:
                // https://github.com/npgsql/npgsql/issues/1214#issuecomment-235828359
                var keepAliveCommand = pgsql.CreateCommand();
                keepAliveCommand.CommandText = "SELECT 1";

                while (!cts.Token.IsCancellationRequested)
                {
                    // Slow down to prevent CPU spike, only query each 200ms
                    await Task.Delay(200, cts.Token);

                    // Reconnect redis if down
                    if (redisConn == null || !redisConn.IsConnected)
                    {
                        Console.WriteLine("Reconnecting Redis");
                        redisConn = OpenRedisConnection();
                        redis = redisConn.GetDatabase();
                    }

                    string json = await redis.ListLeftPopAsync("votes");
                    if (json != null)
                    {
                        var vote = ParseVote(json);
                        Console.WriteLine($"Processing vote for '{vote.Option}' by '{vote.VoterId}'");
                        // Reconnect DB if down
                        if (!pgsql.State.Equals(System.Data.ConnectionState.Open))
                        {
                            Console.WriteLine("Reconnecting DB");
                            pgsql = OpenDbConnection();
                        }
                        else
                        { // Normal +1 vote requested
                            UpdateVote(pgsql, vote.VoterId, vote.Option);
                        }
                    }
                    else
                    {
                        keepAliveCommand.ExecuteNonQuery();
                    }
                }
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine(ex.ToString());
                cts.Cancel();
            }
        }

        private static async Task StartHealthCheckServer(CancellationToken token)
        {
            var listener = new HttpListener();
            listener.Prefixes.Add("http://*:8080/healthz/");
            listener.Start();
            Console.WriteLine("Health check server started at http://*:8080/healthz/");

            while (!token.IsCancellationRequested)
            {
                try
                {
                    var context = await listener.GetContextAsync();
                    context.Response.StatusCode = 200;
                    var responseMessage = "Healthy";
                    byte[] responseBytes = System.Text.Encoding.UTF8.GetBytes(responseMessage);
                    context.Response.OutputStream.Write(responseBytes, 0, responseBytes.Length);
                    context.Response.Close();
                }
                catch (HttpListenerException ex) when (ex.ErrorCode == 995) // Cancelled IO
                {
                    Console.WriteLine("Health check server shutting down.");
                    break;
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine($"Error in health check server: {ex}");
                }
            }

            listener.Close();
        }

        private static NpgsqlConnection OpenDbConnection()
        {
            string connectionString = Environment.GetEnvironmentVariable("POSTGRESQL_CONNECTION_STRING");

            if (string.IsNullOrWhiteSpace(connectionString))
            {
                throw new InvalidOperationException("Environment variable 'POSTGRESQL_CONNECTION_STRING' is not set or empty. Application cannot start.");
            }

            NpgsqlConnection connection;
            while (true)
            {
                try
                {
                    connection = new NpgsqlConnection(connectionString);
                    connection.Open();
                    break;
                }
                catch (SocketException e)
                {
                    Console.Error.WriteLine(e.ToString());
                    Console.Error.WriteLine("Waiting for db");
                    Thread.Sleep(1000);
                }
                catch (DbException e)
                {
                    Console.Error.WriteLine(e.ToString());
                    Console.Error.WriteLine("Waiting for db");
                    Thread.Sleep(1000);
                }
            }

            Console.WriteLine("Connected to db");

            var command = connection.CreateCommand();
            command.CommandText = @"CREATE TABLE IF NOT EXISTS votes (
                                        id VARCHAR(255) NOT NULL UNIQUE,
                                        vote VARCHAR(255) NOT NULL
                                    )";
            command.ExecuteNonQuery();

            return connection;
        }

        private static ConnectionMultiplexer OpenRedisConnection()
        {
            var connectionString = Environment.GetEnvironmentVariable("REDIS_CONNECTION_STRING");

            if (string.IsNullOrWhiteSpace(connectionString))
            {
                throw new InvalidOperationException("Environment variable 'REDIS_CONNECTION_STRING' is not set or empty. Application cannot start.");
            }

            ConnectionMultiplexer connection;
            while (true)
            {
                try
                {
                    connection = ConnectionMultiplexer.Connect(connectionString);
                    break;
                }
                catch (RedisConnectionException)
                {
                    Console.Error.WriteLine("Waiting for redis");
                    Thread.Sleep(1000);
                }
            }
            Console.WriteLine($"Connected to redis");
            return connection;
        }

        // Charge utile déposée dans la file Redis par le front `vote`. Les noms
        // de champs JSON viennent de `vote/app.py` et restent en snake_case ;
        // les propriétés C# suivent la convention du projet, d'où les
        // attributs de mapping plutôt qu'un renommage de part et d'autre.
        public sealed class VotePayload
        {
            [JsonProperty("vote")]
            public string Option { get; set; }

            [JsonProperty("voter_id")]
            public string VoterId { get; set; }
        }

        // Sorti du corps de la boucle pour être testable sans Redis ni Postgres :
        // c'est le seul endroit où le worker interprète une donnée qu'il n'a pas
        // produite. Le comportement est inchangé — une charge utile illisible
        // lève, la boucle appelante l'attrape et arrête le worker.
        public static VotePayload ParseVote(string json)
        {
            return JsonConvert.DeserializeObject<VotePayload>(json);
        }

        private static void UpdateVote(NpgsqlConnection connection, string voterId, string vote)
        {
            var command = connection.CreateCommand();
            try
            {
                command.CommandText = "INSERT INTO votes (id, vote) VALUES (@id, @vote)";
                command.Parameters.AddWithValue("@id", voterId);
                command.Parameters.AddWithValue("@vote", vote);
                command.ExecuteNonQuery();
            }
            catch (DbException)
            {
                command.CommandText = "UPDATE votes SET vote = @vote WHERE id = @id";
                command.ExecuteNonQuery();
            }
            finally
            {
                command.Dispose();
            }
        }
    }
}

using Newtonsoft.Json;
using Worker;
using Xunit;

namespace Worker.Tests
{
    // Ces tests portent sur le seul endroit où le worker interprète une donnée
    // venue de l'extérieur : le JSON déposé dans la file Redis par le front
    // `vote`. Le reste de `Program` ouvre des connexions réseau et n'est pas
    // testable sans réécriture — c'est le sujet du Sprint 2 (`SUIVI.md`).
    public class ParseVoteTests
    {
        [Fact]
        public void ParseVote_WithPayloadFromVoteFront_MapsBothFields()
        {
            var json = @"{""vote"": ""a"", ""voter_id"": ""abc123""}";

            var payload = Program.ParseVote(json);

            Assert.Equal("a", payload.Option);
            Assert.Equal("abc123", payload.VoterId);
        }

        [Fact]
        public void ParseVote_WithUnknownField_IgnoresIt()
        {
            // Le front peut enrichir sa charge utile sans casser le worker.
            var json = @"{""vote"": ""b"", ""voter_id"": ""abc123"", ""sent_at"": ""2026-08-08""}";

            var payload = Program.ParseVote(json);

            Assert.Equal("b", payload.Option);
            Assert.Equal("abc123", payload.VoterId);
        }

        [Fact]
        public void ParseVote_WithMissingVoterId_LeavesItNull()
        {
            // Documente le comportement réel, qui n'est pas celui qu'on voudrait :
            // rien ne rejette une charge utile incomplète ici, et `UpdateVote`
            // insérera un identifiant nul en base. Validation à ajouter au
            // Sprint 2, avec le passage à EF Core.
            var json = @"{""vote"": ""a""}";

            var payload = Program.ParseVote(json);

            Assert.Equal("a", payload.Option);
            Assert.Null(payload.VoterId);
        }

        [Fact]
        public void ParseVote_WithMalformedJson_Throws()
        {
            // Comportement hérité, volontairement inchangé par l'extraction :
            // l'exception remonte à la boucle de `Main`, qui annule le token et
            // arrête le worker. Un message illisible suffit donc à le tuer —
            // mais pas à le bloquer : `ListLeftPop` a déjà retiré le message de
            // la file avant que la conversion n'échoue. App Service redémarre
            // le conteneur, la charge utile fautive a disparu, et le worker
            // repart. Le vote est perdu, silencieusement ; c'est ce point-là
            // qui reste à corriger, pas une boucle de crash.
            var json = "{ pas du json";

            Assert.Throws<JsonReaderException>(() => Program.ParseVote(json));
        }
    }
}

// SPDX-License-Identifier: MIT
// Part of the exchange protocol: the JSON must be the one Swift's Codable writes on macOS, so that a job
// folder written on either system is read by the other. Keep this copy and TreeLevel's identical.

using System.Text.Json;
using System.Text.Json.Serialization;

namespace TreeLevel.MC;

/// <summary>Enum values as Swift writes them: the raw value, which is the lowercased case name
/// (<c>pythia8</c>, <c>queued</c>…).</summary>
public sealed class LowercaseEnumPolicy : JsonNamingPolicy
{
    public override string ConvertName(string name) => name.ToLowerInvariant();
}

/// <summary>Swift's <c>JSONEncoder</c> writes a <c>Date</c> with its default strategy: the number of seconds
/// since 1 January 2001 UTC, Apple's reference date. Nothing else in the protocol needs a converter.</summary>
public sealed class AppleDateConverter : JsonConverter<DateTimeOffset>
{
    static readonly DateTimeOffset Reference = new(2001, 1, 1, 0, 0, 0, TimeSpan.Zero);

    public override DateTimeOffset Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options)
    {
        // A number is the Swift form; a string is accepted so that a hand-written file still loads.
        if (reader.TokenType == JsonTokenType.String && DateTimeOffset.TryParse(reader.GetString(), out var parsed)) return parsed;
        return Reference.AddSeconds(reader.GetDouble());
    }

    public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options)
        => writer.WriteNumberValue((value - Reference).TotalSeconds);
}

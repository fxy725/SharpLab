using Microsoft.CodeAnalysis.Text;
using MirrorSharp.Internal.Handlers.Shared;
using Xunit;

public class CompletionTextChangeTests {
    // The live server returned an empty change at (0, 0) for this Console
    // completion. Expanding that sentinel to the cursor deleted the prefix.
    [Theory]
    [InlineData("")]
    [InlineData("using System;\r\nclass C { void M() { ")]
    [InlineData("// 保留用户代码 😀\r\nclass C { void M() { ")]
    public void EmptyProviderChangeCompletesOnlyTheCurrentWord(string prefix) {
        var source = SourceText.From(prefix + "Con } }");
        var change = CompletionTextChange.Normalize(
            new TextChange(default, ""), new TextSpan(prefix.Length, 3), prefix.Length + 3, "Console"
        );

        Assert.Equal(prefix + "Console } }", source.WithChanges(change).ToString());
        Assert.Equal(prefix.Length, change.Span.Start);
        Assert.Equal(3, change.Span.Length);
    }

    [Fact]
    public void EmptyProviderChangeIncludesTextTypedSinceTheListWasOpened() {
        var change = CompletionTextChange.Normalize(
            new TextChange(default, ""), new TextSpan(10, 1), 14, "Console"
        );
        Assert.Equal(new TextSpan(10, 4), change.Span);
        Assert.Equal("Console", change.NewText);
    }

    [Fact]
    public void NormalProviderChangeRetainsProviderInsertionText() {
        var change = CompletionTextChange.Normalize(
            new TextChange(new TextSpan(10, 1), "global::System.Console"), new TextSpan(10, 1), 13, "Console"
        );
        Assert.Equal(new TextSpan(10, 3), change.Span);
        Assert.Equal("global::System.Console", change.NewText);
    }

    [Fact]
    public void NonemptyDocumentWideProviderChangeIsPreserved() {
        var change = CompletionTextChange.Normalize(
            new TextChange(new TextSpan(0, 20), "using System;\r\nConsole"), new TextSpan(17, 3), 20, "Console"
        );
        Assert.Equal(new TextSpan(0, 20), change.Span);
        Assert.Equal("using System;\r\nConsole", change.NewText);
    }

    [Fact]
    public void CompletionAtTheBeginningOfAnEmptyDocumentStillInsertsText() {
        var change = CompletionTextChange.Normalize(
            new TextChange(default, ""), new TextSpan(0, 0), 0, "class"
        );
        Assert.Equal("class", SourceText.From("").WithChanges(change).ToString());
    }

    [Fact]
    public void ARealDeletionIsNotMistakenForTheMissingProviderSentinel() {
        var change = CompletionTextChange.Normalize(
            new TextChange(new TextSpan(10, 3), ""), new TextSpan(10, 3), 13, "Console"
        );
        Assert.Equal(new TextSpan(10, 3), change.Span);
        Assert.Equal("", change.NewText);
    }
}

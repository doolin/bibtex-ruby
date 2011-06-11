#--
# BibTeX-Ruby
# Copyright (C) 2010-2011 Sylvester Keil <http://sylvester.keil.or.at>
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.	See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program.	If not, see <http://www.gnu.org/licenses/>.
#++

require 'strscan'
require 'forwardable'

module BibTeX
	
	#
	# The BibTeX::Lexer handles the lexical analysis of BibTeX bibliographies.
	#
	class Lexer
	  extend Forwardable

		attr_reader :options, :stack, :mode, :scanner
		
    def_delegator :@scanner, :string, :data

    DEFAULTS = { :include => [:errors], :strict => true }.freeze
    
    
		#
		# Creates a new instance. Possible options and their respective
		# default values are:
		#
		# - :include => [:errors] A list that may contain :meta_content, and
		#		:errors; depending on whether or not these are present, the respective
		#		tokens are included in the parse tree.
		# - :strict => true In strict mode objects can start anywhere; therefore
		#		the `@' symbol is not possible except inside literals or @comment
		#		objects; for a more lenient lexer set to false and objects are
		#		expected to start after a new line (leading white space is permitted).
		#
		def initialize(options = {})
      @options = DEFAULTS.merge(options)
		end

    def reset
			@stack = []
			@brace_level = 0
			@mode = :meta
			@active_object = nil
			@scanner.reset unless @scanner.nil?
    end
    
		# Sets the source for the lexical analysis and resets the internal state.
		def data=(data)
		  reset
			@scanner = StringScanner.new(data)
		end

    def symbols
      @stack.map(&:first)
    end
    
		# Returns the line number at a given position in the source.
		def line_number_at(index)
			0 # (@line_breaks.find_index { |n| n >= index } || 0) + 1
		end
		
		# Returns the next token from the parse stack.
		def next_token
			@stack.shift
		end

		def mode=(mode)
      Log.debug("Lexer: switching to #{mode} mode...")

			@active_object = case
				when [:comment,:string,:preamble,:entry].include?(mode) then mode
				when mode == :meta then nil
				else @active_object
			end

			@mode = mode
		end
		
		# Returns true if the lexer is currenty parsing a BibTeX object.
		def bibtex_mode?
			[:bibtex,:comment,:string,:preamble,:entry].include?(self.mode)
		end
				
		%w{ meta literal content }.each do |m|
      define_method "#{m}_mode?" do
        mode == m.to_sym
      end
		end

		# Returns true if the lexer is currently parsing the given object type.
		def active?(object)
			@active_object == object
		end
		
		# Returns true if the lexer is currently in strict mode.
		def strict?; !!(@options[:strict]); end
		
		# Pushes a value onto the parse stack.
		def push(value)
			case
			when ([:CONTENT,:STRING_LITERAL].include?(value[0]) && value[0] == @stack.last[0])
				@stack.last[1][0] << value[1]
				@stack.last[1][1] = @scanner.pos
			when value[0] == :ERROR
				@stack.push(value) if @options[:include].include?(:errors)
				leave_object
			when value[0] == :META_CONTENT
				if @options[:include].include?(:meta_content)
					value[1] = [value[1], @scanner.pos]
					@stack.push(value)
				end
			else
				value[1] = [value[1], @scanner.pos]
				@stack.push(value)
			end
			self
		end

		# Start the lexical analysis.
		def analyse(data=nil)
			raise(ArgumentError, 'Lexer: failed to start analysis: no source given!') if data.nil? && @scanner.nil?
			Log.debug('Lexer: starting lexical analysis...')
			
			self.data = data || @scanner.string
			
			until @scanner.eos?
				case
				when bibtex_mode?
					parse_bibtex
				when meta_mode?
					parse_meta
				when content_mode?
					parse_content
				when literal_mode?
					parse_literal
				end
			end
			
			Log.debug('Lexer: finished lexical analysis.')
			Log.debug(@stack.inspect)
			push [false, '$end']
		end

		def parse_bibtex
			case
			when @scanner.scan(/[\t\r\n\s]+/o)
			when @scanner.scan(/\{/o)
				@brace_level += 1
				push [:LBRACE,'{']
				if (@brace_level == 1 && active?(:comment)) || (@brace_level > 1 )
					self.mode = :content
				end
			when @scanner.scan(/\}/o)
				return error_unbalanced_braces if @brace_level < 1
				@brace_level -= 1
				push [:RBRACE,'}']
				leave_object if @brace_level == 0
			when @scanner.scan( /=/o)
				push [:EQ,'=']
			when @scanner.scan(/,/o)
				push [:COMMA,',']
			when @scanner.scan(/#/o)
				push [:SHARP,'#']
			when @scanner.scan(/\d+/o)
				push [:NUMBER,@scanner.matched]
			when @scanner.scan(/[a-z\d\/:_!$\.%&*-]+/io)
				push [:NAME,@scanner.matched]
			when @scanner.scan(/"/o)
				self.mode = :literal
			when @scanner.scan(/@/o)
				error_unexpected_token
				enter_object
			when @scanner.scan(/./o)
				error_unexpected_token
				enter_object
			end
		end
		
		def parse_meta
			match = @scanner.scan_until(strict? ? /@[\t ]*/o : /(^|\n)[\t ]*@[\t ]*/o)
			unless @scanner.matched.nil?
				push [:META_CONTENT, match.chop]
				enter_object
			else
				push [:META_CONTENT,@scanner.rest]
				@scanner.terminate
			end
		end

		def parse_content
			match = @scanner.scan_until(/\{|\}/o)
			case @scanner.matched
			when '{'
				@brace_level += 1
				push [:CONTENT,match]
			when '}'
				@brace_level -= 1
				case
				when @brace_level < 0
					push [:CONTENT,match.chop]
					error_unbalanced_braces
				when @brace_level == 0
					push [:CONTENT,match.chop]
					push [:RBRACE,'}']
					leave_object
				when @brace_level == 1 && (active?(:entry) || active?(:string))
					push [:CONTENT,match.chop]
					push [:RBRACE,'}']
					self.mode = :bibtex
				else
					push [:CONTENT, match]
				end
			else
				push [:CONTENT,@scanner.rest]
				@scanner.terminate
				error_unterminated_content
			end
		end
		
		def parse_literal
			match = @scanner.scan_until(/[\{\}"\n]/o)
			case @scanner.matched
			when '{'
				@brace_level += 1
				push [:STRING_LITERAL,match]
			when '}'
				@brace_level -= 1
				if @brace_level < 1
					push [:STRING_LITERAL,match.chop]
					error_unbalanced_braces
				else
					push [:STRING_LITERAL,match]
				end
			when '"'
				if @brace_level == 1
					push [:STRING_LITERAL,match.chop]
					self.mode = :bibtex
				else
					push [:STRING_LITERAL,match]
				end
			when "\n"
				push [:STRING_LITERAL,match.chop]
				error_unterminated_string
			else
				push [:STRING_LITERAL,@scanner.rest]
				@scanner.terminate
				error_unterminated_string
			end
		end
		
		# Called when the lexer encounters a new BibTeX object.
		def enter_object
			@brace_level = 0
			self.mode = :bibtex
			push [:AT,'@']

			case
			when @scanner.scan(/string/io)
				self.mode = :string
				push [:STRING, @scanner.matched]
			when @scanner.scan(/preamble/io)
				self.mode = :preamble
				push [:PREAMBLE, @scanner.matched]
			when @scanner.scan(/comment/io)
				self.mode = :comment
				push [:COMMENT, @scanner.matched]
			when @scanner.scan(/[a-z\d:_!\.$%&*-]+/io)
				self.mode = :entry
				push [:NAME, @scanner.matched]
			end
		end

		# Called when parser leaves a BibTeX object.
		def leave_object
			self.mode = :meta
			@brace_level = 0
		end


		def error_unbalanced_braces
			n = @scanner.pos
			Log.warn("Lexer: unbalanced braces at #{n}; brace level #{@brace_level}; mode #{@mode.inspect}.")
			backtrace [:E_UNBALANCED_BRACES, [@scanner.matched,n]]
		end
		
		def error_unterminated_string
			n = @scanner.pos
			Log.warn("Lexer: unterminated string at #{n}; brace level #{@brace_level}; mode #{@mode.inspect}.")
			backtrace [:E_UNTERMINATED_STRING, [@scanner.matched,n]]
		end

		def error_unterminated_content
			n = @scanner.pos
			Log.warn("Lexer: unterminated content at #{n}; brace level #{@brace_level}; mode #{@mode.inspect}.")
			backtrace [:E_UNTERMINATED_CONTENT, [@scanner.matched,n]]
		end
		
		def error_unexpected_token
			n = @scanner.pos
			Log.warn("Lexer: unexpected token `#{@scanner.matched}' at #{n}; brace level #{@brace_level}; mode #{@mode.inspect}.")
			backtrace [:E_UNEXPECTED_TOKEN, [@scanner.matched,n]]
		end
		
		def backtrace(error)
			trace = []
			trace.unshift(@stack.pop) until @stack.empty? || (!trace.empty? && [:AT,:META_CONTENT].include?(trace[0][0]))
			trace << error
			push [:ERROR,trace]
		end

	end
	
end
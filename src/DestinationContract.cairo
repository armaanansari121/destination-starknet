use starknet::{ContractAddress};

#[starknet::interface]
pub trait IDestinationContract<TContractState> {
    fn request_loan(
        ref self: TContractState,
        borrower_eth: felt252,
        borrower: ContractAddress,
        amount: u256,
        interest_rate: u256,
        duration_in_days: u256,
        credit_score: u256,
    );
    fn fund_loan(ref self: TContractState, borrower: ContractAddress);
    fn get_loan_status(
        self: @TContractState, borrower: ContractAddress,
    ) -> (bool, bool, u256, u256);
    fn repay_loan(ref self: TContractState, amount: u256);
    fn liquidate_loan(ref self: TContractState, borrower: ContractAddress);
    fn calculate_total_due(self: @TContractState, borrower: ContractAddress) -> u256;
    fn get_loan_details(
        self: @TContractState, borrower: ContractAddress,
    ) -> (u256, u256, u256, u256, u256, bool, bool);
    fn withdraw_tokens(ref self: TContractState, amount: u256);
}

#[starknet::contract]
pub mod DestinationContract {
    use starknet::event::EventEmitter;
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address, get_contract_address};
    use starknet::storage::{
        StoragePointerWriteAccess, StoragePointerReadAccess, StoragePathEntry, Map,
    };
    use crate::LendingToken::{ILendingTokenDispatcher, ILendingTokenDispatcherTrait};
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::security::ReentrancyGuardComponent;

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(
        path: ReentrancyGuardComponent, storage: reentrancy_guard, event: ReentrancyGuardEvent,
    );

    #[abi(embed_v0)]
    impl OwnableImpl = OwnableComponent::OwnableImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;
    impl ReentrancyInternalImpl = ReentrancyGuardComponent::InternalImpl<ContractState>;

    #[derive(Drop, starknet::Store)]
    struct Loan {
        borrower_eth: felt252,
        amount: u256,
        repaid_amount: u256,
        interest_rate: u256,
        due_date: u256,
        credit_score: u256,
        active: bool,
        funded: bool,
    }

    #[storage]
    struct Storage {
        lending_token: ContractAddress,
        loans: Map<ContractAddress, Loan>,
        liquidation_threshold: u256,
        ltv_rtio: u256,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        reentrancy_guard: ReentrancyGuardComponent::Storage,
    }

    #[derive(Drop, starknet::Event)]
    struct LoanRequested {
        borrower: ContractAddress,
        amount: u256,
        interest_rate: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct LoanFunded {
        borrower: ContractAddress,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct LoanRepaid {
        borrower_eth: felt252,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct LoanFullyRepaid {
        borrower_eth: felt252,
    }

    #[derive(Drop, starknet::Event)]
    struct LoanLiquidated {
        borrower_eth: felt252,
        amount: u256,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        LoanRequested: LoanRequested,
        LoanFunded: LoanFunded,
        LoanRepaid: LoanRepaid,
        LoanFullyRepaid: LoanFullyRepaid,
        LoanLiquidated: LoanLiquidated,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        ReentrancyGuardEvent: ReentrancyGuardComponent::Event,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState, lending_token: ContractAddress, owner: ContractAddress,
    ) {
        self.ownable.initializer(owner);
        self.lending_token.write(lending_token);
    }

    #[abi(embed_v0)]
    impl IDestinationContract of super::IDestinationContract<ContractState> {
        fn request_loan(
            ref self: ContractState,
            borrower_eth: felt252,
            borrower: ContractAddress,
            amount: u256,
            interest_rate: u256,
            duration_in_days: u256,
            credit_score: u256,
        ) {
            let loan = self.loans.entry(borrower).read();

            assert!(!loan.active, "Borrower has an active loan");
            let loan = Loan {
                borrower_eth,
                amount,
                repaid_amount: 0,
                interest_rate,
                due_date: get_block_timestamp().try_into().unwrap() + (duration_in_days * 86400),
                credit_score,
                active: true,
                funded: false,
            };

            self.loans.entry(borrower).write(loan);
            self.emit(LoanRequested { borrower, amount, interest_rate });
        }

        fn fund_loan(ref self: ContractState, borrower: ContractAddress) {
            self.reentrancy_guard.start();

            let loan = self.loans.entry(borrower).read();
            assert!(loan.active && !loan.funded, "Loan is not active or already funded");

            self.loans.entry(borrower).write(Loan { funded: true, ..loan });

            let lending_token_address = self.lending_token.read();
            let lending_token = ILendingTokenDispatcher { contract_address: lending_token_address };

            lending_token.mint(borrower, loan.amount);
            self.emit(LoanFunded { borrower, amount: loan.amount });
            self.reentrancy_guard.end();
        }

        fn get_loan_status(
            self: @ContractState, borrower: ContractAddress,
        ) -> (bool, bool, u256, u256) {
            let lending_token_address = self.lending_token.read();
            let lending_token = IERC20Dispatcher { contract_address: lending_token_address };
            let loan = self.loans.entry(borrower).read();
            return (loan.active, loan.funded, loan.amount, lending_token.balance_of(borrower));
        }

        fn repay_loan(ref self: ContractState, amount: u256) {
            self.reentrancy_guard.start();
            let borrower = get_caller_address();
            let loan = self.loans.entry(borrower).read();
            assert!(loan.active, "Loan is not active");
            assert!(loan.funded, "Loan is not funded");

            let total_due = self.calculate_total_due(borrower);
            assert!(amount <= total_due, "Repayment amount exceeds total due");

            let lending_token_address = self.lending_token.read();
            let lending_token = ILendingTokenDispatcher { contract_address: lending_token_address };
            lending_token.burn(borrower, amount);

            self
                .loans
                .entry(borrower)
                .write(Loan { repaid_amount: loan.repaid_amount + amount, ..loan });
            self.emit(LoanRepaid { borrower_eth: loan.borrower_eth, amount });

            let loan  = self.loans.entry(borrower).read();

            if loan.repaid_amount >= total_due {
                self.loans.entry(borrower).write(Loan { active: false, ..loan });
                self.emit(LoanFullyRepaid { borrower_eth: loan.borrower_eth });

                let loan = self.loans.entry(borrower).read();

                let overpayment = loan.repaid_amount - total_due;
                if overpayment > 0 {
                    lending_token.mint(borrower, overpayment);
                }
            }
            self.reentrancy_guard.end();
        }

        fn liquidate_loan(ref self: ContractState, borrower: ContractAddress) {
            self.ownable.assert_only_owner();
            let loan = self.loans.entry(borrower).read();
            assert!(loan.active, "Loan is not active");
            assert!(loan.funded, "Loan is not funded");

            let total_due: u256 = self.calculate_total_due(borrower);
            let liquidation_threshold = self.liquidation_threshold.read();
            let liquidation_value: u256 = total_due * liquidation_threshold / 100;

            assert!(loan.repaid_amount < liquidation_value, "Loan is not eligible for liquidation");

            let liquidation_amount: u256 = total_due - loan.repaid_amount;
            self.loans.entry(borrower).write(Loan { active: false, ..loan });
            self.emit(LoanLiquidated { borrower_eth: loan.borrower_eth, amount: liquidation_amount });
        }

        fn calculate_total_due(self: @ContractState, borrower: ContractAddress) -> u256 {
            let loan = self.loans.entry(borrower).read();
            if !loan.active || !loan.funded {
                return 0;
            }

            let principle = loan.amount;

            // Calculate time elapsed since loan start (30 days before due date)
            let loan_start_time = loan.due_date - 30 * 86400;
            let block_timestamp: u256 = get_block_timestamp().try_into().unwrap();
            let mut time_elapsed: u256 = 0;
            if block_timestamp > loan_start_time {
                time_elapsed = block_timestamp - loan_start_time;
            } else {
                time_elapsed = 0;
            }

            let interest = (principle * loan.interest_rate * time_elapsed) / (365 * 86400 * 10000);
            let total_due = principle + interest;

            if total_due > loan.repaid_amount {
                return total_due - loan.repaid_amount;
            } else {
                return 0;
            }
        }

        fn get_loan_details(
            self: @ContractState, borrower: ContractAddress,
        ) -> (u256, u256, u256, u256, u256, bool, bool) {
            let loan = self.loans.entry(borrower).read();
            return (
                loan.amount,
                loan.repaid_amount,
                loan.interest_rate,
                loan.due_date,
                loan.credit_score,
                loan.active,
                loan.funded,
            );
        }

        fn withdraw_tokens(ref self: ContractState, amount: u256) {
            self.ownable.assert_only_owner();
            let lending_token_address = self.lending_token.read();
            let lending_token = IERC20Dispatcher { contract_address: lending_token_address };
            assert!(
                amount <= lending_token.balance_of(get_contract_address()), "Insufficient balance",
            );

            let success = lending_token.transfer(self.ownable.owner(), amount);
            assert!(success, "Token transfer failed");
        }
    }
}
